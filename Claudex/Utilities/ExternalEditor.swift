//
//  ExternalEditor.swift
//  Claudex
//
//  Open files in external editors.
//

import Foundation
import AppKit

enum ExternalEditor {
    static func openInAntigravity(_ url: URL) {
        let path = url.path

        // 1. Try the antigravity CLI if installed
        let candidatePaths = [
            "/usr/local/bin/antigravity",
            "/opt/homebrew/bin/antigravity",
            "\(NSHomeDirectory())/.local/bin/antigravity"
        ]
        for cli in candidatePaths where FileManager.default.isExecutableFile(atPath: cli) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = [path]
            do { try p.run(); Logger.shared.info("Opened in Antigravity via \(cli)") }
            catch { Logger.shared.warn("antigravity CLI at \(cli) failed: \(error)") }
            return
        }

        // 2. Try Launch Services with bundle identifier
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Antigravity") {
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) { _, error in
                if let error { Logger.shared.error("Antigravity open failed: \(error)") }
            }
            return
        }

        // 3. Fallback: NSWorkspace.open (user's default for this directory)
        Logger.shared.warn("Antigravity not found; falling back to NSWorkspace.open")
        NSWorkspace.shared.open(url)
    }

    static func openInTerminal(_ url: URL) {
        let script = "tell application \"Terminal\" to do script \"cd \\\"\(url.path)\\\"\""
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", script]
        try? p.run()
    }

    static func openInVSCode(_ url: URL) {
        let path = url.path
        let candidatePaths = [
            "/usr/local/bin/code",
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        ]
        for cli in candidatePaths where FileManager.default.isExecutableFile(atPath: cli) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = [path]
            do { try p.run(); Logger.shared.info("Opened in VS Code via \(cli)") }
            catch { Logger.shared.warn("VS Code CLI at \(cli) failed: \(error)") }
            return
        }
        Logger.shared.warn("VS Code not found; falling back to NSWorkspace.open")
        NSWorkspace.shared.open(url)
    }
}