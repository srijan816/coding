//
//  TerminalPaneView.swift
//  ClaudeDeck
//
//  Terminal pane scoped to project cwd.
//

import SwiftUI

struct TerminalPaneView: View {
    let project: Project?

    var body: some View {
        VStack {
            if let project = project {
                TerminalView(projectRoot: project.rootPath)
            } else {
                Text("No project selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Terminal View (placeholder until SwiftTerm integration)

struct TerminalView: View {
    let projectRoot: URL

    @State private var terminalOutput: String = ""
    @State private var inputText: String = ""
    @State private var shellProcess: Process?
    @State private var isRunning: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Terminal output
            ScrollView {
                Text(terminalOutput)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            // Input row
            HStack {
                Text("$")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)

                TextField("", text: $inputText)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .onSubmit {
                        runCommand()
                    }

                Button("Run") {
                    runCommand()
                }
                .buttonStyle(.bordered)
                .disabled(inputText.isEmpty || !isRunning)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .onAppear { initializeShell() }
        .onDisappear { shellProcess?.terminate() }
    }

    private func initializeShell() {
        // Initialize with working directory info
        terminalOutput = "Working directory: \(projectRoot.path)\n"
        terminalOutput += "SHELL: \(ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")\n\n"
        isRunning = true
    }

    private func runCommand() {
        let cmd = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }

        terminalOutput += "$ \(cmd)\n"
        inputText = ""

        // Echo the command output for now - a real implementation would use a PTY
        // See PRD §10.3 for SwiftTerm integration notes
        terminalOutput += "(terminal output would appear here with PTY support)\n\n"
    }
}

#Preview {
    TerminalPaneView(project: .placeholder)
}