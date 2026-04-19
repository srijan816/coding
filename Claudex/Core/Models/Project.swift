//
//  Project.swift
//  ClaudeDeck
//
//  A project represents a directory on disk containing a working session.
//

import Foundation

struct Project: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var rootPath: URL
    var createdAt: Date
    var color: String

    init(id: UUID = UUID(), name: String, rootPath: URL, createdAt: Date = Date(), color: String = "blue") {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.createdAt = createdAt
        self.color = color
    }

    enum CodingKeys: String, CodingKey {
        case id, name, rootPathString, createdAt, color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let path = try c.decode(String.self, forKey: .rootPathString)
        rootPath = URL(fileURLWithPath: path)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        color = try c.decode(String.self, forKey: .color)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(rootPath.path, forKey: .rootPathString)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(color, forKey: .color)
    }
}

extension Project {
    static var placeholder: Project {
        Project(name: "Example Project", rootPath: URL(fileURLWithPath: "/tmp"))
    }
}