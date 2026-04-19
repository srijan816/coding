//
//  ThreadEngineV2.swift
//  Claudex
//
//  Refactored ThreadEngine using PTY + LocalAPIProxy interceptor pattern.
//  Instead of parsing fragile CLI stdout/ANSI output, we intercept the actual
//  API calls the CLI makes and drive UI state directly from pristine JSON.
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

    private var proxy: LocalAPIProxy?
    private var pty: PTYConnection?
    private var proxyTask: Task<Void, Never>?
    private var ptyOutputTask: Task<Void, Never>?
    private var settingsFileURL: URL?

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

        // Build arguments for interactive mode (NO -p flag)
        var args: [String] = [
            "--no-input",
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

        // PTY output is for debugging only in this mode
        ptyOutputTask = Task.detached { [weak self] in
            guard let pty = self?.pty else { return }
            for await data in pty.output {
                // Log PTY output for debugging (contains ANSI formatting)
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    Logger.shared.info("ThreadEngineV2 PTY: \(text.prefix(200))")
                }
            }
        }

        // Termination handler via polling
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            while self.pty?.isRunning == true {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            // Process ended
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

        // Create proxy for env provider mode too
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
            "--no-input",
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

        ptyOutputTask = Task.detached { [weak self] in
            guard let pty = self?.pty else { return }
            for await data in pty.output {
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    Logger.shared.info("ThreadEngineV2 PTY: \(text.prefix(200))")
                }
            }
        }

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            while self.pty?.isRunning == true {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            Logger.shared.info("ThreadEngineV2: PTY ended")
            if self.state.isRunning {
                self.state = .idle
            }
        }
    }

    // MARK: - Handle Proxy Events

    @MainActor
    private func handleProxyEvent(_ event: APIEvent) {
        switch event {
        case .request(let info):
            Logger.shared.info("ThreadEngineV2 API request: \(info.method) \(info.path) bodySize=\(info.body?.count ?? 0)")

            // Parse request body to extract messages/tool calls
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

            // Parse response to extract assistant messages and tool results
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
                            appendOrCoalesceAssistantText(text)
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

    // MARK: - Send Message

    func send(_ userText: String) async throws {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await MainActor.run {
            self.messages.append(.user(trimmed, Date()))
        }
        Logger.shared.info("ThreadEngineV2.send: user text (\(trimmed.count) chars)")

        // Ensure PTY is running
        if pty == nil || !(pty?.isRunning ?? false) {
            try await start()
        }

        guard let currentPTY = pty, currentPTY.isRunning else {
            throw NSError(domain: "ThreadEngineV2", code: 1, userInfo: [NSLocalizedDescriptionKey: "PTY not running after start"])
        }

        // Write user message to PTY
        let jsonPayload = """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"\(trimmed.replacingOccurrences(of: "\"", with: "\\\""))"}]}}
        """ + "\n"

        do {
            try currentPTY.writeString(jsonPayload)
            Logger.shared.info("ThreadEngineV2.send: wrote \(jsonPayload.count) bytes to PTY")
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
