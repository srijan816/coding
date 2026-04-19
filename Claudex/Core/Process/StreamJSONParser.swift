//
//  StreamJSONParser.swift
//  ClaudeDeck
//
//  Parses NDJSON from claude's stdout into typed ClaudeEvent values.
//

import Foundation

// MARK: - ClaudeEvent

enum ClaudeEvent: Equatable {
    case systemInit(SystemInit)
    case systemApiRetry(ApiRetry)
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolUse(ToolUse)
    case toolResult(ToolResultEvent)
    case result(ResultEvent)
    case unknown(rawJSON: String)

    static func == (lhs: ClaudeEvent, rhs: ClaudeEvent) -> Bool {
        switch (lhs, rhs) {
        case (.systemInit(let l), .systemInit(let r)): return l == r
        case (.systemApiRetry(let l), .systemApiRetry(let r)): return l == r
        case (.user(let l), .user(let r)): return l == r
        case (.assistant(let l), .assistant(let r)): return l == r
        case (.toolUse(let l), .toolUse(let r)): return l == r
        case (.toolResult(let l), .toolResult(let r)): return l == r
        case (.result(let l), .result(let r)): return l == r
        case (.unknown(let l), .unknown(let r)): return l == r
        default: return false
        }
    }
}

// MARK: - Event Payloads

struct SystemInit: Equatable {
    let sessionId: String
    let model: String
    let tools: [[String: AnyCodable]]
    let mcpServers: [String]
}

struct ApiRetry: Equatable {
    let attempt: Int
    let message: String?
}

struct UserMessage: Equatable {
    let content: String
}

struct AssistantMessage: Equatable {
    let content: [ContentBlock]
}

enum ContentBlock: Equatable {
    case text(String)
    case toolUse(name: String, input: [String: AnyCodable], id: String)
}

struct ToolUse: Equatable {
    let id: UUID
    let name: String
    let input: [String: AnyCodable]
}

struct ToolResultEvent: Equatable {
    let toolUseId: UUID
    let content: String
    let isError: Bool
}

struct ResultEvent: Equatable {
    let text: String
    let sessionId: String?
    let totalCostUsd: Double?
    let durationMs: Int?
    let numTurns: Int?
    let isError: Bool
    let totalTokens: Int?
}

// MARK: - Parser

final class StreamJSONParser: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    var events: AsyncStream<ClaudeEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    private var continuation: AsyncStream<ClaudeEvent>.Continuation?

    func feed(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        lock.unlock()

        processBuffer()
    }

    private func processBuffer() {
        lock.lock()
        defer { lock.unlock() }

        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = Data(buffer[..<newlineIndex])
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])

            // Process on background
            Task {
                await parseLine(lineData)
            }
        }
    }

    private func parseLine(_ data: Data) {
        guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty else {
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let type = json["type"] as? String else {
            // Malformed JSON — emit as unknown
            continuation?.yield(.unknown(rawJSON: line))
            return
        }

        switch type {
        case "system":
            handleSystem(json)
        case "user":
            handleUser(json)
        case "assistant":
            handleAssistant(json)
        case "tool_use":
            handleToolUse(json)
        case "tool_result":
            handleToolResult(json)
        case "result":
            handleResult(json)
        default:
            continuation?.yield(.unknown(rawJSON: line))
        }
    }

    private func handleSystem(_ json: [String: Any]) {
        guard let subtype = json["subtype"] as? String else { return }

        if subtype == "init" {
            let sessionId = json["session_id"] as? String ?? ""
            let model = json["model"] as? String ?? ""
            let tools = json["tools"] as? [[String: Any]] ?? []
            let mcpServers = json["mcp_servers"] as? [String] ?? []

            let mappedTools = tools.map { tool -> [String: AnyCodable] in
                tool.mapValues { AnyCodable($0) }
            }

            let initEvent = SystemInit(
                sessionId: sessionId,
                model: model,
                tools: mappedTools,
                mcpServers: mcpServers
            )
            continuation?.yield(.systemInit(initEvent))
        } else if subtype == "api_retry" {
            let attempt = json["attempt"] as? Int ?? 0
            let message = json["message"] as? String
            continuation?.yield(.systemApiRetry(ApiRetry(attempt: attempt, message: message)))
        }
    }

    private func handleUser(_ json: [String: Any]) {
        if let message = json["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]],
           let first = content.first,
           let text = first["text"] as? String {
            continuation?.yield(.user(UserMessage(content: text)))
        }
    }

    private func handleAssistant(_ json: [String: Any]) {
        guard let content = json["content"] as? [[String: Any]] else { return }

        var blocks: [ContentBlock] = []
        for item in content {
            if let text = item["text"] as? String {
                blocks.append(.text(text))
            } else if let toolUse = item["type"] as? String, toolUse == "tool_use",
                      let name = item["name"] as? String,
                      let input = item["input"] as? [String: Any],
                      let id = item["id"] as? String {
                let mappedInput = input.mapValues { AnyCodable($0) }
                blocks.append(.toolUse(name: name, input: mappedInput, id: id))
            }
        }

        continuation?.yield(.assistant(AssistantMessage(content: blocks)))
    }

    private func handleToolUse(_ json: [String: Any]) {
        guard let idStr = json["id"] as? String,
              let id = UUID(uuidString: idStr),
              let name = json["name"] as? String,
              let input = json["input"] as? [String: Any] else { return }

        let mappedInput = input.mapValues { AnyCodable($0) }
        continuation?.yield(.toolUse(ToolUse(id: id, name: name, input: mappedInput)))
    }

    private func handleToolResult(_ json: [String: Any]) {
        guard let toolUseIdStr = json["tool_use_id"] as? String,
              let toolUseId = UUID(uuidString: toolUseIdStr),
              let content = json["content"] as? String else { return }

        let isError = json["is_error"] as? Bool ?? false
        continuation?.yield(.toolResult(ToolResultEvent(toolUseId: toolUseId, content: content, isError: isError)))
    }

    private func handleResult(_ json: [String: Any]) {
        let text = json["text"] as? String ?? ""
        let sessionId = json["session_id"] as? String
        let totalCostUsd = json["total_cost_usd"] as? Double
        let durationMs = json["duration_ms"] as? Int
        let numTurns = json["num_turns"] as? Int
        let isError = json["is_error"] as? Bool ?? false
        let totalTokens = json["total_tokens"] as? Int

        continuation?.yield(.result(ResultEvent(
            text: text,
            sessionId: sessionId,
            totalCostUsd: totalCostUsd,
            durationMs: durationMs,
            numTurns: numTurns,
            isError: isError,
            totalTokens: totalTokens
        )))
    }
}