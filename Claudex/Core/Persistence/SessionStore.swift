//
//  SessionStore.swift
//  ClaudeDeck
//
//  Read-only view of ~/.claude/projects/ for session discovery and history.
//

import Foundation

struct SessionSummary: Identifiable, Equatable {
    let id: UUID
    let sessionId: String
    let title: String
    let createdAt: Date
    let lastModified: Date
}

final class SessionStore {
    static let shared = SessionStore()

    private let claudeDir: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.claudeDir = home.appendingPathComponent(".claude/projects")
    }

    // MARK: - List Sessions for Project

    func listSessions(for project: Project) -> [SessionSummary] {
        let encoded = PathEncoder.encode(project.rootPath)
        let projectDir = claudeDir.appendingPathComponent(encoded)

        guard FileManager.default.fileExists(atPath: projectDir.path) else {
            return []
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            return contents.compactMap { url -> SessionSummary? in
                guard url.pathExtension == "jsonl" else { return nil }

                let filename = url.lastPathComponent
                let sessionId = String(filename.dropLast(6)) // remove .jsonl

                guard let uuid = UUID(uuidString: sessionId) else { return nil }

                // Read first line for title and createdAt
                guard let firstLine = try? String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines).first else {
                    return SessionSummary(id: uuid, sessionId: sessionId, title: "Session", createdAt: Date(), lastModified: Date())
                }

                let createdAt = parseTimestamp(from: firstLine) ?? Date()
                let title = extractTitle(from: firstLine) ?? "Session"

                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let lastModified = attrs?[.modificationDate] as? Date ?? Date()

                return SessionSummary(
                    id: uuid,
                    sessionId: sessionId,
                    title: title,
                    createdAt: createdAt,
                    lastModified: lastModified
                )
            }.sorted { $0.lastModified > $1.lastModified }

        } catch {
            return []
        }
    }

    // MARK: - Parse JSONL Messages

    func messages(for sessionId: String, in project: Project) throws -> AsyncThrowingStream<Message, Error> {
        let encoded = PathEncoder.encode(project.rootPath)
        let fileURL = claudeDir.appendingPathComponent("\(sessionId).jsonl")

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let content = try String(contentsOf: fileURL, encoding: .utf8)
                    for line in content.components(separatedBy: .newlines) {
                        if let message = parseMessage(from: line) {
                            continuation.yield(message)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Helpers

    private func parseTimestamp(from line: String) -> Date? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = json["timestamp"] as? TimeInterval else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func extractTitle(from line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            return nil
        }

        let truncated = text.prefix(60)
        return truncated.count < text.count ? "\(truncated)..." : String(truncated)
    }

    private func parseMessage(from line: String) -> Message? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        let timestamp = (json["timestamp"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) } ?? Date()

        switch type {
        case "user":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]],
               let first = content.first,
               let text = first["text"] as? String {
                return .user(text, timestamp)
            }
        case "assistant":
            if let content = json["content"] as? [[String: Any]] {
                for item in content {
                    if let text = item["text"] as? String {
                        return .assistantText(text, timestamp)
                    }
                }
            }
        case "tool_use":
            if let name = json["name"] as? String,
               let input = json["input"] as? [String: Any],
               let idStr = json["id"] as? String,
               let id = UUID(uuidString: idStr) {
                let mappedInput = input.mapValues { AnyCodable($0) }
                return .toolCall(ToolCall(id: id, name: name, input: mappedInput), timestamp)
            }
        case "tool_result":
            if let content = json["content"] as? String,
               let toolUseIdStr = json["tool_use_id"] as? String,
               let toolUseId = UUID(uuidString: toolUseIdStr) {
                let isError = json["is_error"] as? Bool ?? false
                return .toolResult(ToolResult(id: UUID(), toolUseId: toolUseId, content: content, isError: isError), timestamp)
            }
        default:
            return nil
        }

        return nil
    }
}