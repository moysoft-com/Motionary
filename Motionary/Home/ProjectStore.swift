// Project metadata, content, and imported-media persistence.

import Foundation

enum ProjectStoreError: LocalizedError {
    case mediaCopyFailed(String)

    var errorDescription: String? {
        switch self {
        case .mediaCopyFailed(let message):
            "The media could not be copied into the project: \(message)"
        }
    }
}

/// Owns dashboard projects and their on-disk content directories.
final class ProjectStore: ObservableObject {
    @Published var projects: [Project] = [] {
        didSet {
            save()
        }
    }
    @Published private(set) var posterRevision: Int = 0

    private let storageURL: URL
    let repository: ProjectRepository
    private var contentCache: [UUID: ProjectContent] = [:]
    private var contentWarmupTasks: [UUID: Task<Void, Never>] = [:]
    private var isLoading = false
    private let fileManager = FileManager.default

    init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let rootURL = documentsURL ?? FileManager.default.temporaryDirectory
        storageURL = rootURL
            .appendingPathComponent("projects.json")
        repository = ProjectRepository(rootURL: rootURL)
        load()
        warmRecentProjectContent()
    }

    func addProject(title: String? = nil) -> Project {
        let newProject = Project(title: title ?? "Project #\(projects.count + 1)")
        projects.append(newProject)
        sortProjectsByLastEdited()
        return newProject
    }

    func deleteProject(with id: UUID) {
        projects.removeAll { $0.id == id }
        deleteContent(for: id)
    }

    func finalizeRename(projectID: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let trimmedTitle = projects[index].title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty ? "Untitled Project" : trimmedTitle
        projects[index].title = title
        projects[index].updatedAt = Date()
        sortProjectsByLastEdited()

        let repository = repository
        Task {
            do {
                _ = try await repository.load(
                    projectID: projectID,
                    preferredTitle: title
                )
            } catch ProjectRepositoryError.missingContent {
                try? await repository.save(
                    ProjectContent(editorProject: EditorProject.empty(title: title)),
                    projectID: projectID
                )
            } catch {
                AppLogger.persistence.error(
                    "Failed to synchronize renamed project: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        guard let data = try? Data(contentsOf: storageURL) else { return }
        do {
            let loadedProjects = try JSONDecoder().decode([Project].self, from: data)
            projects = loadedProjects.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            AppLogger.persistence.error("Failed to load projects: \(error.localizedDescription, privacy: .public)")
        }
    }

    func save() {
        guard !isLoading else { return }
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            AppLogger.persistence.error("Failed to save projects: \(error.localizedDescription, privacy: .public)")
        }
    }

    func recordSavedContent(_ content: ProjectContent, projectID: UUID) {
        contentCache[projectID] = content
        syncProjectMetadata(projectID: projectID, content: content)
    }

    func cachedContent(for projectID: UUID) -> ProjectContent? {
        contentCache[projectID]
    }

    func bestAvailableContent(for project: Project) -> ProjectContent {
        contentCache[project.id] ?? ProjectContent(editorProject: EditorProject.empty(title: project.title))
    }

    func warmContent(for project: Project) {
        guard contentCache[project.id] == nil,
            contentWarmupTasks[project.id] == nil
        else { return }

        let projectID = project.id
        let title = project.title
        let repository = repository
        contentWarmupTasks[projectID] = Task { @MainActor [weak self] in
            defer {
                self?.contentWarmupTasks[projectID] = nil
            }
            do {
                let result = try await repository.load(
                    projectID: projectID,
                    preferredTitle: title
                )
                guard !Task.isCancelled else { return }
                self?.contentCache[projectID] = result.content
            } catch ProjectRepositoryError.missingContent {
                let content = ProjectContent(editorProject: EditorProject.empty(title: title))
                self?.contentCache[projectID] = content
            } catch {
                AppLogger.persistence.warning(
                    "Failed to warm project content: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func storeMedia(from url: URL, projectID: UUID) throws -> URL {
        let folderURL = projectFolderURL(for: projectID)
        if url.deletingLastPathComponent() == folderURL {
            return url
        }
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        let destinationURL = folderURL.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: url, to: destinationURL)
            return destinationURL
        } catch {
            AppLogger.persistence.error("Failed to store media: \(error.localizedDescription, privacy: .public)")
            throw ProjectStoreError.mediaCopyFailed(error.localizedDescription)
        }
    }

    func resolvedMediaURL(_ url: URL, projectID: UUID) -> URL {
        if fileManager.fileExists(atPath: url.path) {
            return url
        }

        let candidate = projectFolderURL(for: projectID).appendingPathComponent(url.lastPathComponent)
        if fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        return url
    }

    func derivedMediaURL(fileName: String, projectID: UUID) -> URL {
        projectFolderURL(for: projectID).appendingPathComponent(fileName)
    }

    func posterURL(for projectID: UUID) -> URL {
        projectFolderURL(for: projectID).appendingPathComponent("poster.png")
    }

    func existingPosterURL(for projectID: UUID) -> URL? {
        let url = posterURL(for: projectID)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func removePoster(for projectID: UUID) {
        let url = posterURL(for: projectID)
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
        notePosterChanged()
    }

    func notePosterChanged() {
        posterRevision &+= 1
    }

    private func deleteContent(for projectID: UUID) {
        contentCache[projectID] = nil
        contentWarmupTasks[projectID]?.cancel()
        contentWarmupTasks[projectID] = nil
        let contentURL = contentURL(for: projectID)
        if fileManager.fileExists(atPath: contentURL.path) {
            try? fileManager.removeItem(at: contentURL)
        }
        let folderURL = projectFolderURL(for: projectID)
        if fileManager.fileExists(atPath: folderURL.path) {
            try? fileManager.removeItem(at: folderURL)
        }
    }

    private func contentURL(for projectID: UUID) -> URL {
        projectFolderURL(for: projectID).appendingPathComponent("content.json")
    }

    private func projectFolderURL(for projectID: UUID) -> URL {
        let documentsURL =
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let folderURL = documentsURL.appendingPathComponent("project_\(projectID.uuidString)", isDirectory: true)
        if !fileManager.fileExists(atPath: folderURL.path) {
            try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
        return folderURL
    }

    private func syncProjectMetadata(projectID: UUID, content: ProjectContent) {
        if let index = projects.firstIndex(where: { $0.id == projectID }) {
            projects[index].updatedAt = content.editorProject.updatedAt
        } else {
            projects.append(
                Project(
                    id: projectID,
                    title: content.editorProject.title,
                    createdAt: content.editorProject.createdAt,
                    updatedAt: content.editorProject.updatedAt
                )
            )
        }
        sortProjectsByLastEdited()
    }

    private func sortProjectsByLastEdited() {
        projects.sort {
            if $0.updatedAt == $1.updatedAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func warmRecentProjectContent() {
        for project in projects.prefix(12) {
            warmContent(for: project)
        }
    }
}
