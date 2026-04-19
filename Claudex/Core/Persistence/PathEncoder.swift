//
//  PathEncoder.swift
//  ClaudeDeck
//
//  Mirrors the encoding used by `~/.claude/projects/<encoded-cwd>/`.
//  Replace every non-alphanumeric character with `-`.
//

import Foundation

enum PathEncoder {
    /// Encodes an absolute path to the format used by claude's session storage.
    /// e.g., "/Users/alice/my project" → "-Users-alice-my-project"
    static func encode(_ url: URL) -> String {
        let absolute = url.standardizedFileURL.path
        return String(absolute.map { char in
            if char.isLetter || char.isNumber {
                return char
            } else {
                return "-"
            }
        })
    }

    /// Decodes a claude session directory name back to a path.
    /// Note: this is ambiguous since multiple paths could encode to the same string,
    /// so this should only be used for display purposes.
    static func decode(_ encoded: String) -> String {
        encoded.replacingOccurrences(of: "-", with: "/")
    }
}