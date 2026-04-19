//
//  SettingsJSONBuilderTests.swift
//  ClaudeDeckTests
//
//  Tests for temporary settings JSON file creation.
//

import XCTest
@testable import ClaudeDeck

final class SettingsJSONBuilderTests: XCTestCase {
    func testWriteCreatesValidJSON() throws {
        let settings = ProviderSettings.miniMaxDefault
        settings.authToken = "sk-test"

        let url = try SettingsJSONBuilder.write(settings: settings)
        defer { SettingsJSONBuilder.delete(url) }

        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json)
        XCTAssertNotNil(json?["env"])

        let env = json?["env"] as? [String: String]
        XCTAssertEqual(env?["ANTHROPIC_AUTH_TOKEN"], "sk-test")
        XCTAssertEqual(env?["ANTHROPIC_BASE_URL"], "https://api.minimax.io/anthropic")
    }

    func testDeleteRemovesFile() throws {
        let settings = ProviderSettings.miniMaxDefault
        let url = try SettingsJSONBuilder.write(settings: settings)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        SettingsJSONBuilder.delete(url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}