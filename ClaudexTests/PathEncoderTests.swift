//
//  PathEncoderTests.swift
//  ClaudeDeckTests
//
//  Tests for path encoding/decoding.
//

import XCTest
@testable import ClaudeDeck

final class PathEncoderTests: XCTestCase {
    func testEncodeSimplePath() {
        let url = URL(fileURLWithPath: "/Users/alice/proj")
        let encoded = PathEncoder.encode(url)
        XCTAssertEqual(encoded, "-Users-alice-proj")
    }

    func testEncodePathWithSpaces() {
        let url = URL(fileURLWithPath: "/Users/alice/my project")
        let encoded = PathEncoder.encode(url)
        XCTAssertEqual(encoded, "-Users-alice-my-project")
    }

    func testEncodePathWithSpecialChars() {
        let url = URL(fileURLWithPath: "/Users/alice/Documents/Code")
        let encoded = PathEncoder.encode(url)
        // Only alphanumeric survive
        XCTAssertTrue(encoded.contains("-"))
        XCTAssertFalse(encoded.contains("/"))
    }

    func testEncodeUnicodePath() {
        let url = URL(fileURLWithPath: "/Users/alice/文档")
        let encoded = PathEncoder.encode(url)
        // Non-ASCII alphanumerics become -
        XCTAssertTrue(encoded.contains("-"))
        XCTAssertFalse(encoded.contains("文"))
    }

    func testDecode() {
        let encoded = "-Users-alice-proj"
        let decoded = PathEncoder.decode(encoded)
        XCTAssertEqual(decoded, "/Users/alice/proj")
    }
}