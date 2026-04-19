//
//  PTYConnection.swift
//  Claudex
//
//  Pseudo-Terminal (PTY) wrapper using the `script` command.
//  This runs the command through a PTY using macOS's built-in `script` utility.
//

import Foundation

enum PTYError: Error, LocalizedError {
    case scriptFailed
    case writeFailed
    case notRunning

    var errorDescription: String? {
        switch self {
        case .scriptFailed: return "script command failed"
        case .writeFailed: return "write to PTY failed"
        case .notRunning: return "PTY is not running"
        }
    }
}

final class PTYConnection: @unchecked Sendable {
    private var process: Process?
    private var masterFD: FileHandle?
    private var slaveFD: FileHandle?
    private let lock = NSLock()
    private var isRunningFlag = false

    var output: AsyncStream<Data> {
        AsyncStream { continuation in
            self.outputContinuation = continuation
        }
    }

    private var outputContinuation: AsyncStream<Data>.Continuation?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunningFlag && (process?.isRunning ?? false)
    }

    /// Spawns a command through a PTY using the `script` command.
    /// The `script` command creates a pseudo-terminal automatically.
    func spawn(command: String, arguments: [String], environment: [String: String]? = nil, workingDirectory: String? = nil) throws {
        // Build environment string for script
        var envArgs: [String] = []
        if let env = environment {
            for (key, value) in env {
                envArgs.append("\(key)=\(value)")
            }
        }

        // Build the command line for script -r means don't record
        // We use /dev/null as the typescript (output file)
        let scriptProcess = Process()
        scriptProcess.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        scriptProcess.arguments = ["-q", "-r", "/dev/null", "/bin/bash", "-c", "\(command) \(arguments.joined(separator: " "))"]

        // Set up environment
        if let env = environment {
            var fullEnv = ProcessInfo.processInfo.environment ?? [:]
            for (key, value) in env {
                fullEnv[key] = value
            }
            scriptProcess.environment = fullEnv
        }

        // Set working directory
        if let cwd = workingDirectory {
            scriptProcess.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        // Create pipe for PTY output
        let outputPipe = Pipe()
        scriptProcess.standardOutput = outputPipe
        scriptProcess.standardError = outputPipe

        // Connect a null device as "input" (we'll write to it)
        let inputPipe = Pipe()
        scriptProcess.standardInput = inputPipe

        self.process = scriptProcess
        self.slaveFD = inputPipe.fileHandleForWriting

        isRunningFlag = true

        // Start reading output
        Task.detached { [weak self] in
            guard let self = self else { return }
            let handle = outputPipe.fileHandleForReading
            while self.isRunning {
                let data = handle.availableData
                if data.isEmpty {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                self.outputContinuation?.yield(data)
            }
        }

        scriptProcess.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.lock.lock()
                self?.isRunningFlag = false
                self?.lock.unlock()
                self?.outputContinuation?.finish()
                Logger.shared.info("PTYConnection: script terminated with status \(process.terminationStatus)")
            }
        }

        try scriptProcess.run()

        // Start output reader on the pipe
        Task.detached { [weak self] in
            guard let self = self else { return }
            let handle = outputPipe.fileHandleForReading
            for try await data in handle.bytes {
                self.outputContinuation?.yield(Data([data]))
            }
            self.outputContinuation?.finish()
        }
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        guard isRunningFlag, let handle = slaveFD else {
            throw PTYError.notRunning
        }

        try handle.write(contentsOf: data)
    }

    func writeString(_ string: String) throws {
        try write(string.data(using: .utf8)!)
    }

    func interrupt() {
        lock.lock()
        defer { lock.unlock() }

        process?.interrupt()
    }

    func terminate() {
        lock.lock()
        isRunningFlag = false
        lock.unlock()

        process?.terminate()
        process = nil
        slaveFD = nil
        masterFD = nil
    }

    deinit {
        terminate()
    }
}
