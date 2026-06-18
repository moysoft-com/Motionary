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

    private let storageURL: URL
    private var isLoading = false
    private let fileManager = FileManager.default

    init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        storageURL = (documentsURL ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("projects.json")
        load()
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

    private func load() {
        isLoading = true
        defer { isLoading = false }
        guard let data = try? Data(contentsOf: storageURL) else { return }
        do {
            var loadedProjects = try JSONDecoder().decode([Project].self, from: data)
            for index in loadedProjects.indices {
                if let content = loadContent(for: loadedProjects[index].id) {
                    loadedProjects[index].updatedAt = max(
                        loadedProjects[index].updatedAt,
                        content.editorProject.updatedAt
                    )
                }
            }
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

    // MARK: - Project Content Persistence

    func loadContent(for projectID: UUID) -> ProjectContent? {
        let contentURL = contentURL(for: projectID)
        guard let data = try? Data(contentsOf: contentURL) else { return nil }
        return try? JSONDecoder().decode(ProjectContent.self, from: data)
    }

    func saveContent(_ content: ProjectContent, for projectID: UUID) {
        let contentURL = contentURL(for: projectID)
        do {
            let data = try JSONEncoder().encode(content)
            try data.write(to: contentURL, options: [.atomic])
            syncProjectMetadata(projectID: projectID, content: content)
        } catch {
            AppLogger.persistence.error(
                "Failed to save project content: \(error.localizedDescription, privacy: .public)"
            )
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

    private func deleteContent(for projectID: UUID) {
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
}
