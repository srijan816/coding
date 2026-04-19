//
//  EnvFileManager.swift
//  ClaudeDeck
//
//  Reads ~/Library/Application Support/ClaudeDeck/.env and produces
//  a cleaned environment for child claude processes.
//

import Foundation

enum EnvFileError: Error, LocalizedError {
    case fileNotFound
    case invalidLine(lineNumber: Int, content: String)
    case saveFailed(Error)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return ".env file not found at expected location"
        case .invalidLine(let lineNumber, let content):
            return "Invalid line \(lineNumber): \(content)"
        case .saveFailed(let error):
            return "Failed to save .env: \(error.localizedDescription)"
        }
    }
}

final class EnvFileManager {
    static let shared = EnvFileManager()

    private let fileURL: URL
    private let appSupportDir: URL

    // Keys to strip from child process environment
    private let stripKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    ]

    init(appSupportDir: URL = EnvFileManager.defaultAppSupportDir) {
        self.appSupportDir = appSupportDir
        self.fileURL = appSupportDir.appendingPathComponent(".env")
    }

    static var defaultAppSupportDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/ClaudeDeck")
    }

    // MARK: - Load

    func load() throws -> ProviderSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw EnvFileError.fileNotFound
        }

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        var values: [String: String] = [:]

        for (lineNumber, line) in content.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip blanks and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Parse KEY=VALUE
            guard let equalIndex = trimmed.firstIndex(of: "=") else {
                throw EnvFileError.invalidLine(lineNumber: lineNumber + 1, content: trimmed)
            }

            let key = String(trimmed[..<equalIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: equalIndex)...]).trimmingCharacters(in: .whitespaces)

            values[key] = value
        }

        return ProviderSettings(
            baseURL: values["ANTHROPIC_BASE_URL"] ?? ProviderSettings.miniMaxDefault.baseURL,
            authToken: values["ANTHROPIC_AUTH_TOKEN"] ?? "",
            model: values["ANTHROPIC_MODEL"] ?? ProviderSettings.miniMaxDefault.model,
            smallFastModel: values["ANTHROPIC_SMALL_FAST_MODEL"] ?? ProviderSettings.miniMaxDefault.smallFastModel,
            defaultSonnetModel: values["ANTHROPIC_DEFAULT_SONNET_MODEL"] ?? ProviderSettings.miniMaxDefault.defaultSonnetModel,
            defaultOpusModel: values["ANTHROPIC_DEFAULT_OPUS_MODEL"] ?? ProviderSettings.miniMaxDefault.defaultOpusModel,
            defaultHaikuModel: values["ANTHROPIC_DEFAULT_HAIKU_MODEL"] ?? ProviderSettings.miniMaxDefault.defaultHaikuModel,
            apiTimeoutMs: Int(values["API_TIMEOUT_MS"] ?? "") ?? ProviderSettings.miniMaxDefault.apiTimeoutMs,
            disableNonessentialTraffic: (values["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] ?? "1") == "1",
            maxContextTokensOverride: values["CLAUDE_CODE_MAX_CONTEXT_TOKENS"]
        )
    }

    // MARK: - Save

    func save(_ settings: ProviderSettings) throws {
        let lines = [
            "# ClaudeDeck configuration — edit this file and restart the app",
            "",
            "ANTHROPIC_BASE_URL=\(settings.baseURL)",
            "ANTHROPIC_AUTH_TOKEN=\(settings.authToken)",
            "ANTHROPIC_MODEL=\(settings.model)",
            "ANTHROPIC_SMALL_FAST_MODEL=\(settings.smallFastModel)",
            "ANTHROPIC_DEFAULT_SONNET_MODEL=\(settings.defaultSonnetModel)",
            "ANTHROPIC_DEFAULT_OPUS_MODEL=\(settings.defaultOpusModel)",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL=\(settings.defaultHaikuModel)",
            "API_TIMEOUT_MS=\(settings.apiTimeoutMs)",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=\(settings.disableNonessentialTraffic ? "1" : "0")",
            settings.maxContextTokensOverride.map { "CLAUDE_CODE_MAX_CONTEXT_TOKENS=\($0)" } ?? "",
        ].filter { !$0.isEmpty }

        let content = lines.joined(separator: "\n") + "\n"

        // Atomic save: write to temp file then rename
        let tempURL = appSupportDir.appendingPathComponent(".env.tmp")
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw EnvFileError.saveFailed(error)
        }
    }

    // MARK: - Build Child Environment

    /// Builds the environment dict to pass to a child claude process.
    /// Follows §3.3 rules: strips existing ANTHROPIC_* vars, adds from .env + fixed values.
    func buildChildEnv() -> [String: String] {
        var env: [String: String] = [:]

        // Start with current process environment
        let currentEnv = ProcessInfo.processInfo.environment ?? [:]
        for (key, value) in currentEnv {
            // Strip conflicting keys
            if key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_") {
                // Skip — will be set explicitly below
            } else {
                // Preserve these
                let preserveKeys = ["PATH", "HOME", "USER", "SHELL", "LANG", "LC_ALL", "TMPDIR"]
                if preserveKeys.contains(key) || key == "TERM" {
                    env[key] = value
                }
            }
        }

        // Ensure TERM is set
        env["TERM"] = "dumb"

        // Load from .env
        if let settings = try? load() {
            env["ANTHROPIC_BASE_URL"] = settings.baseURL
            env["ANTHROPIC_AUTH_TOKEN"] = settings.authToken
            env["ANTHROPIC_MODEL"] = settings.model
            env["ANTHROPIC_SMALL_FAST_MODEL"] = settings.smallFastModel
            env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = settings.defaultSonnetModel
            env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = settings.defaultOpusModel
            env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = settings.defaultHaikuModel
        }

        // Fixed additions
        env["API_TIMEOUT_MS"] = "3000000"
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"

        // Optional context token override
        if let settings = try? load(),
           let override = settings.maxContextTokensOverride,
           !override.isEmpty {
            env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = override
        }

        return env
    }

    /// Builds a minimal environment for cloud-managed mode.
    /// Strips all ANTHROPIC_* vars so the CLI uses its own auth (claude login).
    func buildCloudChildEnv() -> [String: String] {
        var env: [String: String] = [:]

        // Preserve only essential environment variables
        let preserveKeys = ["PATH", "HOME", "USER", "SHELL", "LANG", "LC_ALL", "TMPDIR", "TERM"]
        let currentEnv = ProcessInfo.processInfo.environment ?? [:]
        for (key, value) in currentEnv {
            if preserveKeys.contains(key) {
                env[key] = value
            }
        }

        // Ensure TERM is set
        env["TERM"] = "dumb"

        return env
    }

    // MARK: - File URL

    var envFileURL: URL { fileURL }
}