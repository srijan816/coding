//
//  ContentView.swift
//  ClaudeDeck
//
//  Main 3-pane NavigationSplitView with sidebar, thread detail, and inspector.
//

import SwiftUI

struct ContentView: View {
    @State private var appState = AppState.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(appState: appState)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
        } content: {
            if let thread = appState.selectedThread {
                ThreadView(thread: thread, engine: appState.engine(for: thread.id))
            } else {
                emptyState
            }
        } detail: {
            if appState.inspectorVisible {
                InspectorView(
                    thread: appState.selectedThread,
                    project: appState.selectedProject
                )
                .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleInspector()
                } label: {
                    Image(systemName: columnVisibility == .doubleColumn ? "sidebar.right" : "sidebar.right.fill")
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func toggleInspector() {
        withAnimation {
            columnVisibility = columnVisibility == .doubleColumn ? .all : .doubleColumn
        }
        appState.inspectorVisible = columnVisibility == .all
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack.badge.play")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No thread selected")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Select a thread from the sidebar or create a new one")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}