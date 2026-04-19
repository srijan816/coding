//
//  ClaudeDeckApp.swift
//  ClaudeDeck
//
//  @main entry point
//

import SwiftUI

struct ClaudeDeckApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Thread") {
                    if let projectId = AppState.shared.selectedProjectId {
                        let _ = AppState.shared.createThread(in: projectId)
                    }
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Project…") {
                    AppState.shared.addProjectFromFolder()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandMenu("Thread") {
                Button("Send") {
                    // Send is handled via composer keyboard shortcut
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button("Stop") {
                    if let threadId = AppState.shared.selectedThreadId {
                        AppState.shared.stopEngine(for: threadId)
                    }
                }
                .keyboardShortcut(".", modifiers: .command)

                Divider()

                Button("Export Transcript…") {
                    AppState.shared.exportActiveTranscript()
                }
            }

            CommandMenu("View") {
                Button("Toggle Inspector") {
                    AppState.shared.inspectorVisible.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Toggle Terminal") {
                    AppState.shared.inspectorTab = .terminal
                    AppState.shared.inspectorVisible = true
                }
                .keyboardShortcut("j", modifiers: [.command])
            }

            CommandGroup(after: .windowArrangement) {
                Button("Settings") {
                    // Settings handled via Settings scene
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}