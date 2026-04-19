//
//  SidebarView.swift
//  ClaudeDeck
//
//  Project/thread hierarchy with add/remove/actions.
//

import SwiftUI

struct SidebarView: View {
    var appState: AppState

    var body: some View {
        let _ = Logger.shared.info("SidebarView render: project count = \(appState.projectStore.projects.count)")
        List {
            projectsList
        }
        .navigationTitle("ClaudeDeck")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                addMenu
            }
        }
    }

    @ViewBuilder
    private var projectsList: some View {
        if appState.projects.isEmpty {
            Text("No projects")
                .foregroundStyle(.secondary)
                .italic()
        } else {
            ForEach(appState.projects) { project in
                projectSection(project)
            }
        }
    }

    @ViewBuilder
    private func projectSection(_ project: Project) -> some View {
        Section {
            threadsList(for: project)
        } header: {
            projectHeader(project)
        }
    }

    @ViewBuilder
    private func threadsList(for project: Project) -> some View {
        ForEach(appState.threads(for: project)) { thread in
            threadRow(thread)
        }

        newThreadButton(in: project)
    }

    private func threadRow(_ thread: Thread) -> some View {
        ThreadRow(
            thread: thread,
            isSelected: appState.selectedThreadId == thread.id,
            onSelect: {
                appState.selectedThreadId = thread.id
                appState.selectedProjectId = thread.projectId
            },
            onRename: { newTitle in appState.renameThread(thread.id, to: newTitle) },
            onDelete: { appState.removeThread(thread.id) }
        )
    }

    private func newThreadButton(in project: Project) -> some View {
        Button {
            let _ = appState.createThread(in: project.id)
        } label: {
            Label("New Thread", systemImage: "plus.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func projectHeader(_ project: Project) -> some View {
        ProjectRow(
            project: project,
            onOpenInAntigravity: { ExternalEditor.openInAntigravity(project.rootPath) },
            onShowInFinder: { showProjectInFinder(project) },
            onOpenInTerminal: { ExternalEditor.openInTerminal(project.rootPath) },
            onRemove: { appState.removeProject(project.id) }
        )
    }

    private var addMenu: some View {
        Menu {
            Button("Add Project…") { addProject() }
            Button("Import from Claude Code…") { importFromClaudeCode() }
        } label: {
            Image(systemName: "plus")
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Add Project"
        panel.message = "Pick the root folder of your project. ClaudeDeck will run `claude` with this folder as its working directory."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Resolve to canonical absolute path — no symlinks, no /private prefix weirdness.
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL

        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return
        }

        let _ = appState.addProject(at: resolved)
    }

    private func importFromClaudeCode() {
        let discovered = discoverClaudeCodeProjects()

        if discovered.isEmpty {
            return
        }

        for project in discovered {
            let _ = appState.addProject(at: project.rootPath)
        }
    }

    private func discoverClaudeCodeProjects() -> [DiscoveredProject] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var results: [DiscoveredProject] = []
        for dir in entries {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let jsonlFiles = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }

            let jsonls = jsonlFiles.filter { $0.pathExtension == "jsonl" }
            guard let newest = jsonls.max(by: { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return dateA < dateB
            }) else { continue }

            // Read first line to get cwd
            guard let handle = try? FileHandle(forReadingFrom: newest) else { continue }
            defer { try? handle.close() }
            let firstChunk = handle.readData(ofLength: 64 * 1024)
            guard let text = String(data: firstChunk, encoding: .utf8),
                  let firstLine = text.split(separator: "\n").first,
                  let data = String(firstLine).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = obj["cwd"] as? String else { continue }

            let url = URL(fileURLWithPath: cwd)
            if FileManager.default.fileExists(atPath: cwd) {
                results.append(DiscoveredProject(name: url.lastPathComponent, rootPath: url, sessionCount: jsonls.count))
            }
        }
        return results.sorted { $0.name < $1.name }
    }

    private func showProjectInFinder(_ project: Project) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.rootPath.path)
    }
}

// MARK: - Project Row

struct ProjectRow: View {
    let project: Project
    let onOpenInAntigravity: () -> Void
    let onShowInFinder: () -> Void
    let onOpenInTerminal: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)
            Text(project.name)
                .font(.headline)
            Spacer()
        }
        .contextMenu {
            Button("Open in Antigravity") { onOpenInAntigravity() }
            Button("Open in Terminal") { onOpenInTerminal() }
            Divider()
            Button("Show in Finder") { onShowInFinder() }
            Divider()
            Button("Remove", role: .destructive) { onRemove() }
        }
    }
}

// MARK: - Thread Row

struct ThreadRow: View {
    let thread: Thread
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var isEditing = false
    @State private var editTitle = ""

    var body: some View {
        Group {
            if isEditing {
                TextField("Title", text: $editTitle, onCommit: {
                    onRename(editTitle)
                    isEditing = false
                })
                .textFieldStyle(.roundedBorder)
            } else {
                threadContent
            }
        }
        .contextMenu {
            Button("Rename") {
                editTitle = thread.title
                isEditing = true
            }
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }

    private var threadContent: some View {
        HStack {
            statusIcon
            Text(thread.title.isEmpty ? "New Thread" : thread.title)
                .lineLimit(1)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    private var statusIcon: some View {
        Group {
            switch thread.status {
            case .idle:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            case .running:
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.green)
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
    }
}

#Preview {
    SidebarView(appState: AppState.shared)
}

// MARK: - Discovered Project

struct DiscoveredProject: Identifiable {
    let id = UUID()
    let name: String
    let rootPath: URL
    let sessionCount: Int
}