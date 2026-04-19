//
//  ClaudeModel.swift
//  ClaudeDeck
//
//  Model catalog for dropdown selection.
//

import Foundation

struct ClaudeModel: Codable, Identifiable, Hashable {
    var id: String        // the exact string passed to --model
    var displayName: String
    var provider: String  // "minimax", "anthropic", "glm", etc.
}

enum ClaudeModelCatalog {
    static let defaults: [ClaudeModel] = [
        ClaudeModel(id: "minimax-m2.7:cloud",  displayName: "MiniMax M2.7 (cloud)",  provider: "minimax"),
        ClaudeModel(id: "minimax-m2.5:cloud",  displayName: "MiniMax M2.5 (cloud)",  provider: "minimax"),
        ClaudeModel(id: "sonnet",              displayName: "Claude Sonnet (latest)", provider: "anthropic"),
        ClaudeModel(id: "opus",                displayName: "Claude Opus (latest)",   provider: "anthropic"),
        ClaudeModel(id: "haiku",               displayName: "Claude Haiku (latest)",  provider: "anthropic"),
        ClaudeModel(id: "glm-4.6:cloud",        displayName: "GLM 4.6 (cloud)",        provider: "glm"),
    ]

    static var defaultCloudModel: ClaudeModel {
        defaults.first { $0.id == "minimax-m2.7:cloud" } ?? defaults[0]
    }
}