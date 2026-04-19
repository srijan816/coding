//
//  Settings.swift
//  ClaudeDeck
//
//  Provider and app settings model
//

import Foundation

struct ProviderSettings: Codable, Equatable {
    var baseURL: String
    var authToken: String
    var model: String
    var smallFastModel: String
    var defaultSonnetModel: String
    var defaultOpusModel: String
    var defaultHaikuModel: String
    var apiTimeoutMs: Int
    var disableNonessentialTraffic: Bool
    var maxContextTokensOverride: String?

    static var miniMaxDefault: ProviderSettings {
        ProviderSettings(
            baseURL: "https://api.minimax.io/anthropic",
            authToken: "",
            model: "MiniMax-M2.7",
            smallFastModel: "MiniMax-M2.7",
            defaultSonnetModel: "MiniMax-M2.7",
            defaultOpusModel: "MiniMax-M2.7",
            defaultHaikuModel: "MiniMax-M2.7",
            apiTimeoutMs: 3_000_000,
            disableNonessentialTraffic: true,
            maxContextTokensOverride: "MiniMax-M2.7:200000"
        )
    }
}

enum PermissionMode: String, Codable, CaseIterable {
    case acceptAll = "Accept all"
    case acceptEdits = "Accept edits"
    case manual = "Manual"

    var description: String {
        switch self {
        case .acceptAll: return "All tools approved automatically"
        case .acceptEdits: return "Approve file edits, ask for shell commands"
        case .manual: return "Ask for every tool"
        }
    }
}

struct AppSettings: Codable {
    var maxConcurrentEngines: Int = 8
    var permissionMode: PermissionMode = .acceptEdits
    var launchMode: LaunchMode = .cloudManaged
    var selectedModelId: String = ClaudeModelCatalog.defaultCloudModel.id

    static var `default`: AppSettings { AppSettings() }

    private static let userDefaultsKey = "AppSettings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AppSettings.userDefaultsKey)
        }
    }
}