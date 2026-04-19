//
//  PTYConnection.swift
//  Claudex
//
//  PTY-like wrapper using script command for pseudo-terminal behavior.
//  Provides async output stream and input writing.
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
    private var masterOutput: FileHandle?
    private var slaveInput: FileHandle?
    private let lock = NSLock()
    private var isRunningFlag = false

    private var outputContinuation: AsyncStream<Data>.Continuation?

    var output: AsyncStream<Data> {
        AsyncStream { continuation in
            self.outputContinuation = continuation
        }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunningFlag && (process?.isRunning ?? false)
    }

    /// Spawns a command through a PTY using the `script` command.
    /// The script command creates a pseudo-terminal automatically.
    func spawn(command: String, arguments: [String], environment: [String: String]? = nil, workingDirectory: String? = nil) throws {
        // Build the command string for bash -c
        let argsString = arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        let fullCommand = "\(command) \(argsString)"

        // Set up environment
        var fullEnv = ProcessInfo.processInfo.environment ?? [:]
        if let env = environment {
            for (key, value) in env {
                fullEnv[key] = value
            }
        }

        // Create the script process
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", "/bin/bash", "-c", fullCommand]
        p.environment = fullEnv

        if let cwd = workingDirectory {
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        // Create pipe for output (script outputs to stdout which goes to our pipe)
        let outputPipe = Pipe()
        p.standardOutput = outputPipe
        p.standardError = outputPipe  // Redirect stderr to stdout too

        // For stdin, we need to provide input - use a pipe we'll write to
        let inputPipe = Pipe()
        p.standardInput = inputPipe

        self.process = p
        self.masterOutput = outputPipe.fileHandleForReading
        self.slaveInput = inputPipe.fileHandleForWriting

        lock.lock()
        isRunningFlag = true
        lock.unlock()

        // Handle termination
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                self.isRunningFlag = false
                self.lock.unlock()
                self.outputContinuation?.finish()
                Logger.shared.info("PTYConnection: script terminated with status \(proc.terminationStatus)")
            }
        }

        // Start reading output
        Task.detached { [weak self] in
            guard let self = self else { return }
            let handle = outputPipe.fileHandleForReading
            for try await data in handle.bytes {
                self.outputContinuation?.yield(Data([data]))
            }
            self.outputContinuation?.finish()
        }

        try p.run()
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        guard isRunningFlag, let handle = slaveInput else {
            throw PTYError.notRunning
        }

        try handle.write(contentsOf: data)
        handle.synchronizeFile()  // Ensure data is flushed
    }

    func writeString(_ string: String) throws {
        try write(string.data(using: .utf8) ?? Data())
    }

    func interrupt() {
        process?.interrupt()
    }

    func terminate() {
        lock.lock()
        isRunningFlag = false
        lock.unlock()

        process?.terminate()
        slaveInput?.closeFile()
        masterOutput?.closeFile()
        slaveInput = nil
        masterOutput = nil
        process = nil
    }

    deinit {
        terminate()
    }
}
