import Foundation

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

    func addProject() -> Project {
        let newProject = Project(title: "Project #\(projects.count + 1)")
        projects.append(newProject)
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
            projects = try JSONDecoder().decode([Project].self, from: data)
        } catch {
            print("Failed to load projects: \(error)")
        }
    }

    func save() {
        guard !isLoading else { return }
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            print("Failed to save projects: \(error)")
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
        } catch {
            print("Failed to save project content: \(error)")
        }
    }

    func storeMedia(from url: URL, projectID: UUID) -> URL {
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
            print("Failed to store media: \(error)")
            return url
        }
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
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let folderURL = documentsURL.appendingPathComponent("project_\(projectID.uuidString)", isDirectory: true)
        if !fileManager.fileExists(atPath: folderURL.path) {
            try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
        return folderURL
    }
}
