//
//  ThreadEngineV2.swift
//  Claudex
//
//  ThreadEngine using PTY + LocalAPIProxy interceptor pattern.
//  PTY runs claude interactively, proxy intercepts API calls for UI state.
//

import Foundation

@Observable
final class ThreadEngineV2: @unchecked Sendable, ThreadEngineProtocol {
    let thread: Thread
    let project: Project

    private(set) var messages: [Message] = []
    private(set) var state: EngineState = .idle
    private(set) var currentTokens: Int = 0
    private(set) var lastCostUsd: Double = 0
    private(set) var currentModel: String = ""
    private(set) var terminalOutput: String = ""

    private var proxy: LocalAPIProxy?
    private var pty: PTYConnection?
    private var proxyTask: Task<Void, Never>?
    private var ptyOutputTask: Task<Void, Never>?
    private var settingsFileURL: URL?
    private var outputBuffer = ""

    private let envManager = EnvFileManager.shared

    init(thread: Thread, project: Project) {
        self.thread = thread
        self.project = project
    }

    deinit {
        terminate()
    }

    // MARK: - Start / Resume

    func start() async throws {
        guard state != .running else { return }
        state = .starting

        let cliResult: CLIDetectionResult
        do {
            cliResult = try CLIDetector.shared.resolve()
        } catch {
            await MainActor.run {
                self.state = .errored("claude CLI not found: \(error.localizedDescription)")
            }
            return
        }

        let appSettings = AppSettings.load()
        let launchMode = appSettings.launchMode

        switch launchMode {
        case .cloudManaged:
            try await startCloudManaged(cliURL: cliResult.url, appSettings: appSettings)
        case .envProvider:
            try await startEnvProvider(cliURL: cliResult.url, appSettings: appSettings)
        }
    }

    private func startCloudManaged(cliURL: URL, appSettings: AppSettings) async throws {
        // Get MiniMax endpoint from .env or use default
        let providerSettings = (try? envManager.load()) ?? ProviderSettings.miniMaxDefault

        // Create proxy that intercepts API calls
        let proxyHost = "api.minimax.io"
        let proxyPort: UInt16 = 443
        let authToken = providerSettings.authToken

        let proxy = try LocalAPIProxy(targetHost: proxyHost, targetPort: proxyPort, authToken: authToken)
        self.proxy = proxy

        // Start the proxy
        proxy.start()
        let proxyPortValue = proxy.port
        Logger.shared.info("ThreadEngineV2: proxy started on port \(proxyPortValue)")

        // Set up environment with proxy
        var env = envManager.buildCloudChildEnv()
        env["ANTHROPIC_BASE_URL"] = "http://localhost:\(proxyPortValue)"
        env["ANTHROPIC_AUTH_TOKEN"] = authToken

        // Determine model
        let modelId = thread.modelOverride ?? appSettings.selectedModelId
        currentModel = modelId

        // Build arguments for interactive mode
        var args: [String] = [
            "--verbose",
            "--dangerously-skip-permissions",
            "--model", modelId,
        ]

        if let sessionId = thread.sessionId {
            args.append(contentsOf: ["--resume", sessionId])
        }

        let argvJoined = ([cliURL.path] + args).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        Logger.shared.info("ThreadEngineV2.start: spawning: \(argvJoined)")
        Logger.shared.info("ThreadEngineV2.start: cwd=\(project.rootPath.path) launchMode=cloudManaged model=\(modelId) proxy=localhost:\(proxyPortValue)")

        // Create PTY connection
        let pty = PTYConnection()
        self.pty = pty

        // Spawn via PTY
        try pty.spawn(
            command: cliURL.path,
            arguments: args,
            environment: env,
            workingDirectory: project.rootPath.path
        )

        state = .running

        // Start proxy event processor
        proxyTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            for await event in proxy.events {
                self.handleProxyEvent(event)
            }
        }

        // Route PTY output to terminalOutput buffer
        ptyOutputTask = Task { @MainActor [weak self] in
            guard let self = self, let pty = self.pty else { return }
            for await data in pty.output {
                self.appendTerminalOutput(data)
            }
        }

        // Termination handler
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            while self.pty?.isRunning == true {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            Logger.shared.info("ThreadEngineV2: PTY ended")
            if self.state.isRunning {
                self.state = .idle
            }
        }
    }

    private func startEnvProvider(cliURL: URL, appSettings: AppSettings) async throws {
        let settings: ProviderSettings
        do {
            settings = try envManager.load()
        } catch {
            await MainActor.run {
                self.state = .errored("Failed to load settings: \(error.localizedDescription)")
            }
            return
        }

        let settingsURL: URL
        do {
            settingsURL = try SettingsJSONBuilder.write(settings: settings)
        } catch {
            await MainActor.run {
                self.state = .errored("Failed to write settings file: \(error.localizedDescription)")
            }
            return
        }
        self.settingsFileURL = settingsURL

        // Create proxy for env provider mode
        let proxyHost: String
        if let url = URL(string: settings.baseURL), let host = url.host {
            proxyHost = host
        } else {
            proxyHost = "api.minimax.io"
        }
        let proxyPort: UInt16 = 443

        let proxy = try LocalAPIProxy(targetHost: proxyHost, targetPort: proxyPort, authToken: settings.authToken)
        self.proxy = proxy

        proxy.start()
        let proxyPortValue = proxy.port
        Logger.shared.info("ThreadEngineV2: proxy started on port \(proxyPortValue)")

        var env = envManager.buildChildEnv()
        env["ANTHROPIC_BASE_URL"] = "http://localhost:\(proxyPortValue)"

        let modelId = thread.modelOverride ?? appSettings.selectedModelId
        currentModel = modelId

        var args = [
            "--bare",
            "--verbose",
            "--settings", settingsURL.path,
            "--model", modelId,
        ]

        if let sessionId = thread.sessionId {
            args.append(contentsOf: ["--resume", sessionId])
        }

        let argvJoined = ([cliURL.path] + args).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        Logger.shared.info("ThreadEngineV2.start: spawning: \(argvJoined)")
        Logger.shared.info("ThreadEngineV2.start: cwd=\(project.rootPath.path) launchMode=envProvider model=\(modelId) proxy=localhost:\(proxyPortValue)")

        let pty = PTYConnection()
        self.pty = pty

        try pty.spawn(
            command: cliURL.path,
            arguments: args,
            environment: env,
            workingDirectory: project.rootPath.path
        )

        state = .running

        proxyTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            for await event in proxy.events {
                self.handleProxyEvent(event)
            }
        }

        // Route PTY output to terminalOutput buffer
        ptyOutputTask = Task { @MainActor [weak self] in
            guard let self = self, let pty = self.pty else { return }
            for await data in pty.output {
                self.appendTerminalOutput(data)
            }
        }

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            while self.pty?.isRunning == true {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            Logger.shared.info("ThreadEngineV2: PTY ended")
            if self.state.isRunning {
                self.state = .idle
            }
        }
    }

    // MARK: - Terminal Output

    @MainActor
    private func appendTerminalOutput(_ data: Data) {
        if let text = String(data: data, encoding: .utf8) {
            outputBuffer.append(text)
            // Keep last 100KB of output
            if outputBuffer.count > 100_000 {
                outputBuffer = String(outputBuffer.suffix(50_000))
            }
            terminalOutput = outputBuffer
        }
    }

    // MARK: - Handle Proxy Events

    @MainActor
    private func handleProxyEvent(_ event: APIEvent) {
        switch event {
        case .request(let info):
            Logger.shared.info("ThreadEngineV2 API request: \(info.method) \(info.path) bodySize=\(info.body?.count ?? 0)")

            // Parse request body to extract messages
            if let body = info.body,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if let messages = json["messages"] as? [[String: Any]] {
                    for msg in messages {
                        if let role = msg["role"] as? String,
                           let content = msg["content"] as? [[String: Any]] {
                            for block in content {
                                if block["type"] as? String == "text",
                                   let text = block["text"] as? String {
                                    if role == "user" {
                                        self.messages.append(.user(text, Date()))
                                    }
                                }
                            }
                        }
                    }
                }
            }

        case .response(let info):
            Logger.shared.info("ThreadEngineV2 API response: status=\(info.statusCode) bodySize=\(info.body?.count ?? 0)")

            if let body = info.body,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                // Extract usage/cost
                if let usage = json["usage"] as? [String: Any] {
                    if let tokens = usage["total_tokens"] as? Int {
                        self.currentTokens = tokens
                    }
                }

                // Extract content blocks
                if let content = json["content"] as? [[String: Any]] {
                    for block in content {
                        if block["type"] as? String == "text",
                           let text = block["text"] as? String {
                            self.appendOrCoalesceAssistantText(text)
                        } else if block["type"] as? String == "tool_use",
                                  let name = block["name"] as? String,
                                  let input = block["input"] as? [String: Any],
                                  let id = block["id"] as? String {
                            let toolCall = ToolCall(
                                id: UUID(uuidString: id) ?? UUID(),
                                name: name,
                                input: input.mapValues { AnyCodable($0) }
                            )
                            self.messages.append(.toolCall(toolCall, Date()))
                        }
                    }
                }

                // Check for errors
                if let error = json["error"] as? [String: Any] {
                    let msg = error["message"] as? String ?? "Unknown error"
                    self.messages.append(.error(msg, Date()))
                }
            }

        case .error(let msg):
            Logger.shared.error("ThreadEngineV2 proxy error: \(msg)")
            self.messages.append(.error("Proxy error: \(msg)", Date()))
        }
    }

    private func appendOrCoalesceAssistantText(_ text: String) {
        if let last = messages.last, case .assistantText(let existing, _) = last {
            messages[messages.count - 1] = .assistantText(existing + text, Date())
        } else {
            messages.append(.assistantText(text, Date()))
        }
    }

    // MARK: - Send Message (via PTY stdin)

    func send(_ userText: String) async throws {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await MainActor.run {
            self.messages.append(.user(trimmed, Date()))
        }
        Logger.shared.info("ThreadEngineV2.send: user text (\(trimmed.count) chars)")

        guard let pty = pty, pty.isRunning else {
            // Restart if needed
            try await start()
            guard let pty = self.pty, pty.isRunning else {
                throw NSError(domain: "ThreadEngineV2", code: 1, userInfo: [NSLocalizedDescriptionKey: "PTY not running after start"])
            }
            // Write the message
            try pty.writeString(trimmed + "\n")
            return
        }

        // Write user input to PTY (interactive mode - just send the text with newline)
        do {
            try pty.writeString(trimmed + "\n")
            Logger.shared.info("ThreadEngineV2.send: wrote to PTY")
        } catch {
            Logger.shared.error("ThreadEngineV2.send: write failed: \(error)")
            await MainActor.run {
                self.messages.append(.error("Failed to send: \(error.localizedDescription)", Date()))
            }
            throw error
        }

        await MainActor.run {
            self.state = .running
        }
    }

    // MARK: - Write to PTY (for tool approvals, etc.)

    func writeToPTY(_ text: String) {
        do {
            try pty?.writeString(text)
        } catch {
            Logger.shared.error("ThreadEngineV2.writeToPTY failed: \(error)")
        }
    }

    // MARK: - Interrupt / Terminate

    func interrupt() {
        pty?.interrupt()
    }

    func terminate() {
        proxyTask?.cancel()
        ptyOutputTask?.cancel()
        pty?.terminate()
        proxy?.stop()

        if let url = settingsFileURL {
            SettingsJSONBuilder.delete(url)
            settingsFileURL = nil
        }
    }
}
