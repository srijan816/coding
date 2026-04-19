//
//  Message.swift
//  ClaudeDeck
//
//  Discriminated union over message types in a thread.
//

import Foundation

enum Message: Identifiable, Equatable {
    case user(String, Date)
    case assistantText(String, Date)
    case toolCall(ToolCall, Date)
    case toolResult(ToolResult, Date)
    case systemNote(String, Date)
    case error(String, Date)

    var id: UUID {
        switch self {
        case .user(_, let date): return UUID()
        case .assistantText(_, let date): return UUID()
        case .toolCall(let tc, let date): return tc.id
        case .toolResult(let tr, let date): return UUID()
        case .systemNote(_, let date): return UUID()
        case .error(_, let date): return UUID()
        }
    }

    var timestamp: Date {
        switch self {
        case .user(_, let date): return date
        case .assistantText(_, let date): return date
        case .toolCall(_, let date): return date
        case .toolResult(_, let date): return date
        case .systemNote(_, let date): return date
        case .error(_, let date): return date
        }
    }
}

struct ToolCall: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let input: [String: AnyCodable]
    let createdAt: Date

    init(id: UUID = UUID(), name: String, input: [String: AnyCodable], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.input = input
        self.createdAt = createdAt
    }
}

struct ToolResult: Codable, Identifiable, Equatable {
    let id: UUID
    let toolUseId: UUID
    let content: String
    let isError: Bool
    let createdAt: Date

    init(id: UUID = UUID(), toolUseId: UUID, content: String, isError: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
        self.createdAt = createdAt
    }
}

// MARK: - AnyCodable Helper

struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let string as String:
            try container.encode(string)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let bool as Bool:
            try container.encode(bool)
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (l as String, r as String): return l == r
        case let (l as Int, r as Int): return l == r
        case let (l as Double, r as Double): return l == r
        case let (l as Bool, r as Bool): return l == r
        default: return false
        }
    }
}