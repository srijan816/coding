//
//  LaunchMode.swift
//  ClaudeDeck
//
//  Launch mode enum for cloud-managed vs env-provider modes.
//

import Foundation

enum LaunchMode: String, Codable, CaseIterable, Identifiable {
    case cloudManaged   // claude --model <model>:cloud --dangerously-skip-permissions
    case envProvider    // claude --bare --settings <file>  (original mode, for MiniMax API-key users)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cloudManaged: return "Cloud (delegated to claude login)"
        case .envProvider:  return "API key via .env"
        }
    }
}