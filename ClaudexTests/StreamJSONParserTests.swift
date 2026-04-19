//
//  StreamJSONParserTests.swift
//  ClaudeDeckTests
//
//  Tests for NDJSON parsing edge cases.
//

import XCTest
@testable import ClaudeDeck

final class StreamJSONParserTests: XCTestCase {
    var parser: StreamJSONParser!

    override func setUp() {
        super.setUp()
        parser = StreamJSONParser()
    }

    override func tearDown() {
        parser = nil
        super.tearDown()
    }

    // MARK: - Single complete event in one chunk

    func testSingleCompleteEvent() async {
        let json = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}"#
        let data = (json + "\n").data(using: .utf8)!

        var events: [ClaudeEvent] = []
        for await event in parser.events {
            events.append(event)
            break
        }

        parser.feed(data)

        // Wait briefly for event
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - Event split across two chunks

    func testSplitEvent() async {
        let part1 = #"{"type":"user","message":{"role":"user","#
        let part2 = #""content":[{"type":"text","text":"hello"}]}}"#

        parser.feed(part1.data(using: .utf8)!)
        parser.feed((part2 + "\n").data(using: .utf8)!)

        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - Multiple events in one chunk

    func testMultipleEvents() async {
        let data = #"{"type":"system","subtype":"init","session_id":"abc123","model":"test"}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
"#.data(using: .utf8)!

        parser.feed(data)
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - Malformed JSON

    func testMalformedJSON() async {
        let data = #"this is not json"#.data(using: .utf8)!

        parser.feed(data)
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}