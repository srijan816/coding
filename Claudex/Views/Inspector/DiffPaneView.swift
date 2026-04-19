//
//  DiffPaneView.swift
//  ClaudeDeck
//
//  Shows git diff for changed files in a project.
//

import SwiftUI

struct DiffPaneView: View {
    let project: Project?
    @State private var gitStatus: GitRunner.GitStatus?
    @State private var diffResults: [GitRunner.DiffResult] = []
    @State private var selectedDiff: GitRunner.DiffResult?
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var showCommitSheet = false
    @State private var commitMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            // File list
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let status = gitStatus {
                fileList(status)
            } else {
                Text("No git repository")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await loadGitStatus() }
    }

    @ViewBuilder
    private func fileList(_ status: GitRunner.GitStatus) -> some View {
        List {
            if !status.staged.isEmpty {
                Section("Staged") {
                    ForEach(status.staged, id: \.path) { change in
                        fileRow(change.path, staged: true)
                    }
                }
            }

            if !status.unstaged.isEmpty {
                Section("Changes") {
                    ForEach(status.unstaged, id: \.path) { change in
                        fileRow(change.path, staged: false)
                    }
                }
            }

            if !status.untracked.isEmpty {
                Section("Untracked") {
                    ForEach(status.untracked, id: \.self) { path in
                        Text(path)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if status.staged.isEmpty && status.unstaged.isEmpty && status.untracked.isEmpty {
                Text("Working tree clean")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .frame(maxWidth: 250)
    }

    private func fileRow(_ path: String, staged: Bool) -> some View {
        Button {
            Task { await showDiff(for: path) }
        } label: {
            HStack {
                Image(systemName: staged ? "plus.circle.fill" : "circle")
                    .foregroundStyle(staged ? .green : .orange)
                    .font(.caption)
                Text(path)
                    .lineLimit(1)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func showDiff(for file: String) async {
        guard let project = project else { return }
        let runner = GitRunner(projectRoot: project.rootPath)
        do {
            let diffs = try await runner.diff(for: file)
            selectedDiff = diffs.first
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadGitStatus() async {
        guard let project = project else { return }
        isLoading = true
        defer { isLoading = false }

        let runner = GitRunner(projectRoot: project.rootPath)
        do {
            gitStatus = try await runner.status()
        } catch {
            errorMessage = error.localizedDescription
            gitStatus = nil
        }
    }
}

// MARK: - Diff Editor View

struct DiffEditorView: View {
    let diff: GitRunner.DiffResult?
    @State private var stagedFiles: [String] = []
    @State private var unstagedFiles: [String] = []
    @State private var selectedFile: String?

    var body: some View {
        HSplitView {
            // File list sidebar
            List {
                ForEach(Array((diff?.unifiedDiff ?? "").components(separatedBy: "diff --git").dropFirst()), id: \.self) { section in
                    if !section.isEmpty {
                        let lines = section.components(separatedBy: .newlines)
                        let filePath = lines.first?.components(separatedBy: " b/").last ?? "unknown"
                        Text(filePath)
                            .font(.caption)
                            .padding(.vertical, 2)
                    }
                }
            }
            .frame(minWidth: 150)
            .listStyle(.sidebar)

            // Diff view
            ScrollView {
                if let diff = diff {
                    Text(diff.unifiedDiff)
                        .font(.system(.caption, design: .monospaced))
                        .padding()
                } else {
                    Text("Select a file to view diff")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    DiffPaneView(project: .placeholder)
}