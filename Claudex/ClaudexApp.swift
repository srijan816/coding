//
//  ClaudexApp.swift
//  Claudex
//
//  Created by Srijan Poudel on 19/4/2026.
//

import SwiftUI

@main
struct ClaudexApp: App {
    init() {
        // Launch banner for diagnostics
        Logger.shared.info("========== Claudex launched ==========")
        Logger.shared.info("version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")")
        Logger.shared.info("pid: \(ProcessInfo.processInfo.processIdentifier)")
        do {
            let cli = try CLIDetector.shared.resolve()
            Logger.shared.info("cli detection: \(cli.url.path)")
        } catch {
            Logger.shared.info("cli detection: NOT FOUND - \(error.localizedDescription)")
        }
        let settings = AppSettings.load()
        Logger.shared.info("settings: launchMode=\(settings.launchMode.rawValue) model=\(settings.selectedModelId)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 700)
        }
        .defaultSize(width: 1600, height: 950)
        .windowResizability(.contentMinSize)
    }
}
