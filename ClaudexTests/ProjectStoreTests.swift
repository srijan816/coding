//
//  ProjectStoreTests.swift
//  ClaudeDeckTests
//
//  Tests for project/thread persistence.
//

import XCTest
@testable import ClaudeDeck

final class ProjectStoreTests: XCTestCase {
    var tempDir: URL!
    var store: ProjectStore!

    override func setUp() async throws {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = ProjectStore(appSupportDir: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testAddProject() {
        let url = URL(fileURLWithPath: "/tmp/test")
        let project = store.addProject(at: url)

        XCTAssertEqual(project.name, "test")
        XCTAssertEqual(store.projects.count, 1)
    }

    func testRemoveProject() {
        let url = URL(fileURLWithPath: "/tmp/test")
        let project = store.addProject(at: url)

        store.removeProject(project.id)

        XCTAssertTrue(store.projects.isEmpty)
    }

    func testCreateThread() {
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp/test"))
        let thread = store.createThread(in: project.id, title: "My Thread")

        XCTAssertEqual(thread.title, "My Thread")
        XCTAssertEqual(store.threads.count, 1)
    }

    func testUpdateThread() {
        let project = store.addProject(at: URL(fileURLWithPath: "/tmp/test"))
        var thread = store.createThread(in: project.id)

        thread.title = "Updated"
        store.updateThread(thread)

        let updated = store.threads.first { $0.id == thread.id }
        XCTAssertEqual(updated?.title, "Updated")
    }
}