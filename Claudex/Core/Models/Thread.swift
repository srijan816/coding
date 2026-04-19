//
//  Thread.swift
//  ClaudeDeck
//
//  A thread represents a single claude CLI session (running or historical).
//

import Foundation

enum ThreadStatus: Codable, Equatable, Hashable {
    case idle
    case running
    case error(String)

    var description: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

struct Thread: Codable, Identifiable, Equatable {
    var id: UUID
    var projectId: UUID
    var title: String
    var sessionId: String?
    var modelOverride: String?
    var createdAt: Date
    var lastActivityAt: Date
    var status: ThreadStatus

    init(id: UUID = UUID(), projectId: UUID, title: String, sessionId: String? = nil, modelOverride: String? = nil, createdAt: Date = Date(), lastActivityAt: Date = Date(), status: ThreadStatus = .idle) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.sessionId = sessionId
        self.modelOverride = modelOverride
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.status = status
    }
}

extension Thread: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    static func == (lhs: Thread, rhs: Thread) -> Bool {
        lhs.id == rhs.id
    }
}

extension Thread {
    static var placeholder: Thread {
        Thread(projectId: UUID(), title: "New Thread")
    }
}