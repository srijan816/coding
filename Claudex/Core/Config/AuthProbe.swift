//
//  AuthProbe.swift
//  Claudex
//
//  Probes whether the claude CLI is authenticated via `claude login`.
//

import Foundation

enum AuthProbeResult: Equatable {
    case ok
    case needsLogin
    case cliMissing
    case other(String)
}

enum AuthProbe {
    /// Probes the claude CLI for auth status.
    /// Runs `claude --print "hi"` with a 5-second timeout.
    static func probe() async -> AuthProbeResult {
        let cliResult: CLIDetectionResult
        do {
            cliResult = try CLIDetector.shared.resolve()
        } catch {
            return .cliMissing
        }

        return await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = cliResult.url
            p.arguments = ["--print", "--output-format", "json", "hi"]

            let env = EnvFileManager.shared.buildCloudChildEnv()
            p.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe

            do {
                try p.run()
            } catch {
                continuation.resume(returning: .other(error.localizedDescription))
                return
            }

            // 5-second timeout
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if p.isRunning {
                    p.terminate()
                    continuation.resume(returning: .other("probe timed out"))
                }
            }

            p.waitUntilExit()

            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""

            let resolved: AuthProbeResult
            if p.terminationStatus == 0 {
                resolved = .ok
            } else if errStr.lowercased().contains("login") ||
                        errStr.lowercased().contains("unauthorized") ||
                        errStr.lowercased().contains("authenticate") ||
                        errStr.lowercased().contains("not logged in") {
                resolved = .needsLogin
            } else if errStr.isEmpty {
                resolved = .other("exit \(p.terminationStatus)")
            } else {
                resolved = .other(errStr.prefix(200).description)
            }

            continuation.resume(returning: resolved)
        }
    }
}
