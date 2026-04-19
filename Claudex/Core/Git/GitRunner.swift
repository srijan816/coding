//
//  GitRunner.swift
//  ClaudeDeck
//
//  Wraps git CLI calls for a project directory.
//

import Foundation

final class GitRunner {
    let projectRoot: URL

    init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    // MARK: - Git Status

    struct GitStatus {
        let staged: [FileChange]
        let unstaged: [FileChange]
        let untracked: [String]

        struct FileChange {
            let path: String
            let staged: Bool
        }
    }

    func status() async throws -> GitStatus {
        // git status --porcelain=v2
        let output = try await run(["status", "--porcelain=v2"])

        var staged: [GitStatus.FileChange] = []
        var unstaged: [GitStatus.FileChange] = []
        var untracked: [String] = []

        for line in output.components(separatedBy: .newlines) {
            guard line.count >= 3 else { continue }

            let xy = String(line.prefix(2))
            let path = String(line.dropFirst(3))

            if xy == "??" {
                untracked.append(path)
            } else if xy.first == "1" || xy.first == "2" {
                // Staged if first char not " " or "?"
                let isStaged = xy.first != " " && xy.first != "?"
                let cleanPath = path.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
                if isStaged {
                    staged.append(GitStatus.FileChange(path: cleanPath, staged: true))
                }
                // Check second char for unstaged changes
                if xy.last != " " && xy.last != "?" {
                    unstaged.append(GitStatus.FileChange(path: cleanPath, staged: false))
                }
            }
        }

        return GitStatus(staged: staged, unstaged: unstaged, untracked: untracked)
    }

    // MARK: - Git Diff

    struct DiffResult {
        let unifiedDiff: String
        let file: String
    }

    func diff(for file: String? = nil) async throws -> [DiffResult] {
        var args = ["diff", "--no-color"]
        if let file = file {
            args.append("--")
            args.append(file)
        }

        let output = try await run(args)
        return parseUnifiedDiff(output)
    }

    private func parseUnifiedDiff(_ output: String) -> [DiffResult] {
        var results: [DiffResult] = []
        var currentFile = ""
        var currentDiff = ""

        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("diff --git") {
                if !currentDiff.isEmpty && !currentFile.isEmpty {
                    results.append(DiffResult(unifiedDiff: currentDiff.trimmingCharacters(in: .whitespacesAndNewlines), file: currentFile))
                }
                // Extract file path from "diff --git a/path b/path"
                let parts = line.components(separatedBy: " b/")
                if parts.count > 1 {
                    currentFile = parts[1].trimmingCharacters(in: .whitespaces)
                }
                currentDiff = ""
            }
            currentDiff += line + "\n"
        }

        if !currentDiff.isEmpty && !currentFile.isEmpty {
            results.append(DiffResult(unifiedDiff: currentDiff.trimmingCharacters(in: .whitespacesAndNewlines), file: currentFile))
        }

        return results
    }

    // MARK: - Git Add/Reset/Commit

    func stage(_ files: [String]) async throws {
        var args = ["add"]
        args.append(contentsOf: files)
        _ = try await run(args)
    }

    func unstage(_ files: [String]) async throws {
        var args = ["reset", "HEAD", "--"]
        args.append(contentsOf: files)
        _ = try await run(args)
    }

    func commit(_ message: String) async throws {
        _ = try await run(["commit", "-m", message])
    }

    func revert(_ file: String) async throws {
        _ = try await run(["checkout", "--", file])
    }

    // MARK: - Run Git

    private func run(_ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["git"] + args
            task.currentDirectoryURL = projectRoot

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            do {
                try task.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if task.terminationStatus == 0 {
                continuation.resume(returning: output)
            } else {
                continuation.resume(throwing: NSError(domain: "GitRunner", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output]))
            }
        }
    }
}