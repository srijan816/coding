//
//  CLIDetector.swift
//  ClaudeDeck
//
//  Finds the `claude` binary on the system.
//

import Foundation

enum CLIDetectorError: Error, LocalizedError {
    case notFound
    case versionParseFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "claude CLI not found on this system"
        case .versionParseFailed(let output):
            return "Could not parse claude version from: \(output)"
        }
    }
}

struct CLIDetectionResult {
    let url: URL
    let version: String
}

final class CLIDetector {
    static let shared = CLIDetector()

    // Resolution order per PRD §6.5
    private let searchPaths: [() -> URL?] = [
        // 1. Env override
        {
            if let path = ProcessInfo.processInfo.environment["CLAUDEDECK_CLI_PATH"] {
                return URL(fileURLWithPath: path)
            }
            return nil
        },
        // 2. which claude
        {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["which", "claude"]
            task.standardOutput = Pipe()
            task.standardError = Pipe()

            try? task.run()
            task.waitUntilExit()

            let pipe = task.standardOutput as? Pipe
            let data = pipe?.fileHandleForReading.readDataToEndOfFile()
            guard let output = data.flatMap({ String(data: $0, encoding: .utf8) })?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty,
                  output.hasPrefix("/") else {
                return nil
            }
            return URL(fileURLWithPath: output)
        },
        // 3. Common Homebrew locations
        {
            let paths = [
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ]
            for path in paths {
                if FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
            return nil
        },
        // 4. Local install
        {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let localPath = home.appendingPathComponent(".claude/local/bin/claude")
            if FileManager.default.fileExists(atPath: localPath.path) {
                return localPath
            }
            return nil
        },
    ]

    /// Resolves the claude binary URL and version.
    func resolve() throws -> CLIDetectionResult {
        for searchPath in searchPaths {
            if let url = searchPath() {
                let version = try resolveVersion(url: url)
                return CLIDetectionResult(url: url, version: version)
            }
        }
        throw CLIDetectorError.notFound
    }

    /// Runs `claude --version` and parses the semver string.
    private func resolveVersion(url: URL) throws -> String {
        let task = Process()
        task.executableURL = url
        task.arguments = ["--version"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        try task.run()
        task.waitUntilExit()

        let pipe = task.standardOutput as? Pipe
        let data = pipe?.fileHandleForReading.readDataToEndOfFile()
        guard let output = data.flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw CLIDetectorError.versionParseFailed("no output")
        }

        // Parse first semver-shaped string (e.g., "1.2.3" or "claude 1.2.3")
        let pattern = #"\b(\d+\.\d+\.\d+)\b"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let range = Range(match.range(at: 1), in: output) {
            return String(output[range])
        }

        throw CLIDetectorError.versionParseFailed(output)
    }
}