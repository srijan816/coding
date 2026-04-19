//
//  SettingsJSONBuilder.swift
//  ClaudeDeck
//
//  Writes a temporary settings JSON file for `claude --settings`.
//

import Foundation

enum SettingsJSONBuilderError: Error {
    case jsonEncodingFailed
    case writeFailed(Error)
}

final class SettingsJSONBuilder {
    /// Writes a settings JSON file and returns the URL.
    /// Caller is responsible for deleting the temp file when done.
    static func write(settings: ProviderSettings) throws -> URL {
        let payload: [String: Any] = [
            "env": [
                "ANTHROPIC_BASE_URL": settings.baseURL,
                "ANTHROPIC_AUTH_TOKEN": settings.authToken,
                "ANTHROPIC_MODEL": settings.model,
                "ANTHROPIC_SMALL_FAST_MODEL": settings.smallFastModel,
                "ANTHROPIC_DEFAULT_SONNET_MODEL": settings.defaultSonnetModel,
                "ANTHROPIC_DEFAULT_OPUS_MODEL": settings.defaultOpusModel,
                "ANTHROPIC_DEFAULT_HAIKU_MODEL": settings.defaultHaikuModel,
            ]
        ]

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
        } catch {
            throw SettingsJSONBuilderError.jsonEncodingFailed
        }

        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("claudedeck-settings-\(UUID().uuidString).json")

        do {
            try data.write(to: tempURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            return tempURL
        } catch {
            throw SettingsJSONBuilderError.writeFailed(error)
        }
    }

    /// Deletes a settings file created by `write`.
    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}