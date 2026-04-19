//
//  InspectorView.swift
//  ClaudeDeck
//
//  Inspector with Diff, Terminal, and Session tabs.
//

import SwiftUI

struct InspectorView: View {
    let thread: Thread?
    let project: Project?

    @State private var selectedTab: InspectorTab = .diff

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Diff").tag(InspectorTab.diff)
                Text("Terminal").tag(InspectorTab.terminal)
                Text("Session").tag(InspectorTab.session)
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            switch selectedTab {
            case .diff:
                DiffPaneView(project: project)
            case .terminal:
                TerminalPaneView(project: project)
            case .session:
                SessionInfoView(thread: thread, project: project)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Session Info View

struct SessionInfoView: View {
    let thread: Thread?
    let project: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let thread = thread {
                Group {
                    Text("Session Info")
                        .font(.headline)
                }

                Divider()

                Group {
                    HStack {
                        Text("Session ID:")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let sessionId = thread.sessionId {
                            Button {
                                #if os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(sessionId, forType: .string)
                                #endif
                            } label: {
                                Text(sessionId)
                                    .font(.system(.body, design: .monospaced))
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("New session")
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text("Model:")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(thread.modelOverride ?? "Default")
                            .font(.system(.body, design: .monospaced))
                    }

                    if let project = project {
                        HStack {
                            Text("Working directory:")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(project.rootPath.path)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()
            } else {
                Text("No thread selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
    }
}

#Preview {
    InspectorView(thread: nil, project: .placeholder)
}