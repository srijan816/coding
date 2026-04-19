//
//  ProjectStore.swift
//  ClaudeDeck
//
//  Manages projects.json in ~/Library/Application Support/ClaudeDeck/.
//

import Foundation

final class ProjectStore: Observable {
    static let shared = ProjectStore()

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private(set) var projects: [Project] = []
    private(set) var threads: [Thread] = []

    init(appSupportDir: URL = EnvFileManager.defaultAppSupportDir) {
        // Ensure the app support directory exists before setting file path
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        self.fileURL = appSupportDir.appendingPathComponent("projects.json")
        load()
    }

    // MARK: - Load/Save

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let stored = try decoder.decode(ProjectStoreData.self, from: data)
            self.projects = stored.projects
            self.threads = stored.threads
        } catch {
            print("ProjectStore: failed to load: \(error)")
        }
    }

    private func save() {
        do {
            let stored = ProjectStoreData(projects: projects, threads: threads)
            let data = try encoder.encode(stored)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("ProjectStore: failed to save: \(error)")
        }
    }

    // MARK: - Project CRUD

    func addProject(at url: URL) -> Project {
        Logger.shared.info("ProjectStore.addProject: before count=\(projects.count) instance=\(ObjectIdentifier(self).debugDescription)")
        let project = Project(
            name: url.lastPathComponent,
            rootPath: url
        )
        projects.append(project)
        save()
        Logger.shared.info("ProjectStore.addProject: after count=\(projects.count)")
        return project
    }

    func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        threads.removeAll { $0.projectId == id }
        save()
    }

    func updateProject(_ project: Project) {
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
            save()
        }
    }

    // MARK: - Thread CRUD

    func createThread(in projectId: UUID, title: String = "New Thread") -> Thread {
        let thread = Thread(projectId: projectId, title: title)
        threads.append(thread)
        save()
        return thread
    }

    func updateThread(_ thread: Thread) {
        if let idx = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[idx] = thread
            save()
        }
    }

    func removeThread(_ id: UUID) {
        threads.removeAll { $0.id == id }
        save()
    }

    func threads(for projectId: UUID) -> [Thread] {
        threads.filter { $0.projectId == projectId }
    }

    func project(for threadId: UUID) -> Project? {
        guard let thread = threads.first(where: { $0.id == threadId }) else {
            return nil
        }
        return projects.first { $0.id == thread.projectId }
    }
}

// MARK: - Storage Model

private struct ProjectStoreData: Codable {
    let projects: [Project]
    let threads: [Thread]
}