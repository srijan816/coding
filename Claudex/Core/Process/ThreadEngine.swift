//
//  ThreadEngine.swift
//  ClaudeDeck
//
//  Owns a child `claude` process for a single thread, handles streaming events.
//

import Foundation

enum EngineState: Equatable {
    case idle
    case starting
    case running
    case stopped
    case errored(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

@Observable
final class ThreadEngine: @unchecked Sendable, ThreadEngineProtocol {
    let thread: Thread
    let project: Project

    private(set) var messages: [Message] = []
    private(set) var state: EngineState = .idle
    private(set) var currentTokens: Int = 0
    private(set) var lastCostUsd: Double = 0
    private(set) var currentModel: String = ""

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderrHandle: FileHandle?
    private var parser: StreamJSONParser?
    private var settingsFileURL: URL?
    private var stderrBuffer: String = ""

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
        let p = Process()
        p.executableURL = cliURL
        p.currentDirectoryURL = project.rootPath

        // Determine model: thread.modelOverride takes precedence
        let modelId = thread.modelOverride ?? appSettings.selectedModelId
        currentModel = modelId

        var args = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--dangerously-skip-permissions",
            "--model", modelId,
        ]

        if let sessionId = thread.sessionId {
            args.append(contentsOf: ["--resume", sessionId])
        }

        p.arguments = args
        p.environment = envManager.buildCloudChildEnv()

        let argvJoined = ([cliURL.path] + args).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        Logger.shared.info("ThreadEngine.start: spawning: \(argvJoined)")
        Logger.shared.info("ThreadEngine.start: cwd=\(project.rootPath.path) launchMode=cloudManaged model=\(modelId)")

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        self.stdin = inPipe.fileHandleForWriting
        self.stdout = outPipe.fileHandleForReading
        self.stderrHandle = errPipe.fileHandleForReading
        self.process = p

        let parser = StreamJSONParser()
        self.parser = parser

        // Capture stderr
        Task.detached { [weak self] in
            guard let handle = self?.stderrHandle else { return }
            for try await line in handle.bytes.lines {
                await MainActor.run {
                    self?.appendStderr(line)
                }
            }
        }

        // Consume stdout
        Task.detached { [weak self] in
            guard let self = self, let stdout = self.stdout else { return }
            for try await chunk in stdout.bytes {
                parser.feed(Data([chunk]))
            }
        }

        // Process events on main actor
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            for await event in parser.events {
                self.handle(event)
            }
        }

        // Termination handler
        p.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let code = process.terminationStatus
                let reason = process.terminationReason
                Logger.shared.info("ThreadEngine: child terminated code=\(code) reason=\(reason.rawValue)")
                if code != 0 && self.state.isRunning {
                    let tail = String(self.stderrBuffer.suffix(2000))
                    self.messages.append(.error("claude exited with code \(code).\n\nstderr:\n\(tail.isEmpty ? "(none)" : tail)", Date()))
                    self.state = .errored("exit \(code)")
                } else if self.state.isRunning {
                    self.state = .idle
                }
            }
        }

        do {
            try p.run()
            await MainActor.run {
                self.state = .running
            }
        } catch {
            await MainActor.run {
                self.state = .errored("Failed to start: \(error.localizedDescription)")
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

        let p = Process()
        p.executableURL = cliURL
        p.currentDirectoryURL = project.rootPath

        let modelId = thread.modelOverride ?? appSettings.selectedModelId
        currentModel = modelId

        var args = [
            "--bare",
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--settings", settingsURL.path,
        ]

        if let sessionId = thread.sessionId {
            args.append(contentsOf: ["--resume", sessionId])
        }

        p.arguments = args
        p.environment = envManager.buildChildEnv()

        let argvJoined = ([cliURL.path] + args).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        Logger.shared.info("ThreadEngine.start: spawning: \(argvJoined)")
        Logger.shared.info("ThreadEngine.start: cwd=\(project.rootPath.path) launchMode=envProvider model=\(modelId)")

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        self.stdin = inPipe.fileHandleForWriting
        self.stdout = outPipe.fileHandleForReading
        self.stderrHandle = errPipe.fileHandleForReading
        self.process = p

        let parser = StreamJSONParser()
        self.parser = parser

        // Capture stderr
        Task.detached { [weak self] in
            guard let handle = self?.stderrHandle else { return }
            for try await line in handle.bytes.lines {
                await MainActor.run {
                    self?.appendStderr(line)
                }
            }
        }

        // Consume stdout
        Task.detached { [weak self] in
            guard let self = self, let stdout = self.stdout else { return }
            for try await chunk in stdout.bytes {
                parser.feed(Data([chunk]))
            }
        }

        // Process events on main actor
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            for await event in parser.events {
                self.handle(event)
            }
        }

        // Termination handler
        p.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let code = process.terminationStatus
                let reason = process.terminationReason
                Logger.shared.info("ThreadEngine: child terminated code=\(code) reason=\(reason.rawValue)")
                if code != 0 && self.state.isRunning {
                    let tail = String(self.stderrBuffer.suffix(2000))
                    self.messages.append(.error("claude exited with code \(code).\n\nstderr:\n\(tail.isEmpty ? "(none)" : tail)", Date()))
                    self.state = .errored("exit \(code)")
                } else if self.state.isRunning {
                    self.state = .idle
                }
            }
        }

        do {
            try p.run()
            await MainActor.run {
                self.state = .running
            }
        } catch {
            await MainActor.run {
                self.state = .errored("Failed to start: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func appendStderr(_ line: String) {
        stderrBuffer += line + "\n"
        Logger.shared.warn("claude stderr: \(line)")
        // Only surface to UI if it looks like an error
        let lower = line.lowercased()
        let looksLikeError = lower.contains("error") || lower.contains("fatal") ||
                             lower.contains("must be") || lower.contains("invalid") ||
                             lower.contains("unknown") || lower.contains("failed") ||
                             lower.contains("login") || lower.contains("unauthorized")
        if looksLikeError {
            messages.append(.error(line, Date()))
        }
    }

    // MARK: - Send Message

    func send(_ userText: String) async throws {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 1. Show immediately in UI BEFORE any writes that could fail
        await MainActor.run {
            self.messages.append(.user(trimmed, Date()))
        }
        Logger.shared.info("ThreadEngine.send: user text (\(trimmed.count) chars) appended to transcript")

        // 2. Ensure we have a running child
        if state == .idle || process == nil || !(process?.isRunning ?? false) {
            Logger.shared.info("ThreadEngine.send: no running child, starting one")
            try await start()
        }

        // 3. Encode and write
        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": trimmed]]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var lineData = data
        lineData.append(contentsOf: [0x0A]) // newline

        Logger.shared.info("ThreadEngine.send: writing \(lineData.count) bytes to stdin")
        do {
            try stdin?.write(contentsOf: lineData)
        } catch {
            Logger.shared.error("ThreadEngine.send: stdin write failed: \(error)")
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
        process?.interrupt()
    }

    func terminate() {
        process?.terminate()
        cleanup()
    }

    private func cleanup() {
        stdin?.closeFile()
        stdout?.closeFile()
        stderrHandle?.closeFile()
        stdin = nil
        stdout = nil
        stderrHandle = nil
        process = nil

        if let url = settingsFileURL {
            SettingsJSONBuilder.delete(url)
            settingsFileURL = nil
        }
    }

    // MARK: - Handle Events

    @MainActor
    private func handle(_ event: ClaudeEvent) {
        let preview = String(describing: event).prefix(200)
        Logger.shared.info("ThreadEngine event: \(preview)")

        switch event {
        case .systemInit(let systemInit):
            // Capture session ID for resume
            if thread.sessionId == nil {
                var updatedThread = thread
                updatedThread.sessionId = systemInit.sessionId
                updatedThread.status = .running
                ProjectStore.shared.updateThread(updatedThread)
            }
            state = .running

        case .assistant(let msg):
            for block in msg.content {
                switch block {
                case .text(let text):
                    appendOrCoalesceAssistantText(text)
                case .toolUse(let name, let input, let id):
                    let toolCall = ToolCall(id: UUID(uuidString: id) ?? UUID(), name: name, input: input)
                    messages.append(.toolCall(toolCall, Date()))
                }
            }

        case .toolUse(let toolUse):
            let tc = ToolCall(id: toolUse.id, name: toolUse.name, input: toolUse.input)
            messages.append(.toolCall(tc, Date()))

        case .toolResult(let result):
            attachToolResult(result)

        case .result(let result):
            currentTokens = result.totalTokens ?? currentTokens
            lastCostUsd += result.totalCostUsd ?? 0
            state = .idle

        case .systemApiRetry:
            messages.append(.systemNote("API retry...", Date()))

        case .user:
            break

        case .unknown(let raw):
            messages.append(.systemNote("Unknown event: \(raw.prefix(200))", Date()))
        }
    }

    private func appendOrCoalesceAssistantText(_ text: String) {
        if let last = messages.last, case .assistantText(let existing, _) = last {
            messages[messages.count - 1] = .assistantText(existing + text, Date())
        } else {
            messages.append(.assistantText(text, Date()))
        }
    }

    private func attachToolResult(_ result: ToolResultEvent) {
        let toolResult = ToolResult(
            id: UUID(),
            toolUseId: result.toolUseId,
            content: result.content,
            isError: result.isError
        )
        messages.append(.toolResult(toolResult, Date()))
    }
}