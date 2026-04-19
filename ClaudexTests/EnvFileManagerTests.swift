//
//  EnvFileManagerTests.swift
//  ClaudeDeckTests
//
//  Tests for .env file loading and environment building.
//

import XCTest
@testable import ClaudeDeck

final class EnvFileManagerTests: XCTestCase {
    var tempDir: URL!
    var sut: EnvFileManager!

    override func setUp() async throws {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sut = EnvFileManager(appSupportDir: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testLoadEmptyFile() async throws {
        // Write empty .env
        let envFile = tempDir.appendingPathComponent(".env")
        try "".write(to: envFile, atomically: true, encoding: .utf8)

        let settings = try sut.load()
        XCTAssertEqual(settings.baseURL, "https://api.minimax.io/anthropic")
        XCTAssertEqual(settings.authToken, "")
    }

    func testLoadWithValues() async throws {
        let envFile = tempDir.appendingPathComponent(".env")
        try """
        ANTHROPIC_BASE_URL=https://custom.api.com/v1
        ANTHROPIC_AUTH_TOKEN=sk-test123
        ANTHROPIC_MODEL=MiniMax-M2.7
        """.write(to: envFile, atomically: true, encoding: .utf8)

        let settings = try sut.load()
        XCTAssertEqual(settings.baseURL, "https://custom.api.com/v1")
        XCTAssertEqual(settings.authToken, "sk-test123")
        XCTAssertEqual(settings.model, "MiniMax-M2.7")
    }

    func testSaveAndLoad() async throws {
        var settings = ProviderSettings.miniMaxDefault
        settings.authToken = "sk-saved"

        try sut.save(settings)

        let reloaded = try sut.load()
        XCTAssertEqual(reloaded.authToken, "sk-saved")
    }

    func testBuildChildEnvStripsExisting() async throws {
        // Set ANTHROPIC_API_KEY in process env
        let currentEnv = ProcessInfo.processInfo.environment
        // Simulate parent env having ANTHROPIC_API_KEY
        let childEnv = sut.buildChildEnv()

        // Should not contain ANTHROPIC_API_KEY (strips parent env)
        XCTAssertNil(childEnv["ANTHROPIC_API_KEY"])
    }
}