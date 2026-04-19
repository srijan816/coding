//
//  AppState.swift
//  ClaudeDeck
//
//  Global application state managing projects, threads, and engines.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

enum InspectorTab: String, CaseIterable {
    case diff
    case terminal
    case session
}

@Observable
final class AppState {
    static let shared = AppState()

    let projectStore: ProjectStore

    private(set) var activeEngines: [UUID: ThreadEngineProtocol] = [:]

    var selectedProjectId: UUID?
    var selectedThreadId: UUID?
    var inspectorVisible: Bool = true
    var inspectorTab: InspectorTab = .diff

    init(projectStore: ProjectStore = .shared) {
        self.projectStore = projectStore
    }

    // MARK: - Project Access

    var projects: [Project] { projectStore.projects }

    func project(for threadId: UUID) -> Project? {
        guard let thread = projectStore.threads.first(where: { $0.id == threadId }) else {
            return nil
        }
        return projects.first { $0.id == thread.projectId }
    }

    var selectedProject: Project? {
        guard let id = selectedProjectId else { return nil }
        return projects.first { $0.id == id }
    }

    func threads(for project: Project) -> [Thread] {
        projectStore.threads(for: project.id)
    }

    var selectedThread: Thread? {
        guard let id = selectedThreadId else { return nil }
        return projectStore.threads.first { $0.id == id }
    }

    // MARK: - Engine Management

    func engine(for threadId: UUID) -> ThreadEngineProtocol? {
        activeEngines[threadId]
    }

    func startEngine(for thread: Thread, in project: Project) async throws {
        guard activeEngines[thread.id] == nil else { return }

        // Use ThreadEngineV2 with PTY + LocalAPIProxy interceptor pattern
        let engine = ThreadEngineV2(thread: thread, project: project)
        activeEngines[thread.id] = engine

        try await engine.start()

        // Update thread status
        var updated = thread
        updated.status = .running
        projectStore.updateThread(updated)
    }

    func stopEngine(for threadId: UUID) {
        activeEngines[threadId]?.terminate()
        activeEngines.removeValue(forKey: threadId)
    }

    // MARK: - Project CRUD

    func addProject(at url: URL) -> Project {
        let project = projectStore.addProject(at: url)
        selectedProjectId = project.id
        return project
    }

    func addProjectFromFolder() {
        Logger.shared.info("addProjectFromFolder: invoked")
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Add Project"
        panel.message = "Pick the root folder of your project."

        let response = panel.runModal()
        Logger.shared.info("addProjectFromFolder: panel returned \(response.rawValue) url=\(panel.url?.path ?? "nil")")
        guard response == .OK, let url = panel.url else {
            Logger.shared.warn("addProjectFromFolder: user cancelled or no URL")
            return
        }

        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        Logger.shared.info("addProjectFromFolder: resolved=\(resolved.path) exists=\(FileManager.default.fileExists(atPath: resolved.path))")
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            Logger.shared.warn("addProjectFromFolder: resolved path does not exist")
            return
        }

        let project = addProject(at: resolved)
        Logger.shared.info("addProjectFromFolder: created project id=\(project.id) name=\(project.name)")
    }

    func removeProject(_ id: UUID) {
        if selectedProjectId == id {
            selectedProjectId = nil
        }
        for thread in projectStore.threads(for: id) {
            stopEngine(for: thread.id)
        }
        projectStore.removeProject(id)
    }

    // MARK: - Thread CRUD

    func createThread(in projectId: UUID, title: String = "New Thread") -> Thread {
        let thread = projectStore.createThread(in: projectId, title: title)
        selectedThreadId = thread.id
        return thread
    }

    func removeThread(_ id: UUID) {
        if selectedThreadId == id {
            selectedThreadId = nil
        }
        stopEngine(for: id)
        projectStore.removeThread(id)
    }

    func renameThread(_ id: UUID, to title: String) {
        if var thread = projectStore.threads.first(where: { $0.id == id }) {
            thread.title = title
            projectStore.updateThread(thread)
        }
    }

    // MARK: - Export

    func exportActiveTranscript() {
        guard let thread = selectedThread else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(thread.title.isEmpty ? "transcript" : thread.title).md"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var content = "# \(thread.title.isEmpty ? "Transcript" : thread.title)\n\n"

        let messages = engine(for: thread.id)?.messages ?? []
        for message in messages {
            switch message {
            case .user(let text, let date):
                content += "## User (\(date.formatted()))\n\n\(text)\n\n"
            case .assistantText(let text, _):
                content += "\(text)\n\n"
            case .toolCall(let tc, let date):
                content += "## Tool: \(tc.name) (\(date.formatted()))\n\n```json\n\(tc.input)\n```\n\n"
            case .toolResult(let result, _):
                content += "**Result:** \(result.content)\n\n"
            case .systemNote(let note, _):
                content += "*System: \(note)*\n\n"
            case .error(let text, _):
                content += "**Error:** \(text)\n\n"
            }
        }

        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}