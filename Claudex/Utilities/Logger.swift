//
//  Logger.swift
//  Claudex
//
//  Centralized logging to file + console for debugging.
//

import Foundation

final class Logger: @unchecked Sendable {
    static let shared = Logger()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "claudedeck.logger")

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeDeck/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        self.fileURL = dir.appendingPathComponent("claudedeck-\(stamp).log")
    }

    func log(_ level: String, _ message: String, file: String = #file, line: Int = #line) {
        let entry = "[\(Date().ISO8601Format())] [\(level)] \(URL(fileURLWithPath: file).lastPathComponent):\(line) — \(message)\n"
        queue.async {
            if let data = entry.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: self.fileURL.path) {
                    if let h = try? FileHandle(forWritingTo: self.fileURL) {
                        try? h.seekToEnd()
                        try? h.write(contentsOf: data)
                        try? h.close()
                    }
                } else {
                    try? data.write(to: self.fileURL)
                }
            }
        }
        #if DEBUG
        print(entry, terminator: "")
        #endif
    }

    func info(_ message: String, file: String = #file, line: Int = #line) {
        log("INFO", message, file: file, line: line)
    }

    func warn(_ message: String, file: String = #file, line: Int = #line) {
        log("WARN", message, file: file, line: line)
    }

    func error(_ message: String, file: String = #file, line: Int = #line) {
        log("ERROR", message, file: file, line: line)
    }
}
