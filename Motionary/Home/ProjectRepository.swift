import Foundation

enum ProjectRepositoryError: LocalizedError {
    case missingContent
    case corruptedContent(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingContent:
            "No saved project content was found."
        case .corruptedContent(let message):
            "The project content is corrupted: \(message)"
        case .saveFailed(let message):
            "The project could not be saved: \(message)"
        }
    }
}

enum ProjectContentSource: Sendable, Equatable {
    case primary
    case recovery
    case backup
}

struct ProjectLoadResult: Sendable {
    let content: ProjectContent
    let source: ProjectContentSource
}

actor ProjectRepository {
    private let rootURL: URL
    private let fileManager = FileManager.default

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func load(
        projectID: UUID,
        preferredTitle: String? = nil
    ) throws -> ProjectLoadResult {
        let folderURL = projectFolderURL(for: projectID)
        let candidates: [(ProjectContentSource, URL)] = [
            (.primary, folderURL.appendingPathComponent("content.json")),
            (.recovery, folderURL.appendingPathComponent("content.recovery.json")),
            (.backup, folderURL.appendingPathComponent("content.backup.json"))
        ]
        guard candidates.contains(where: { fileManager.fileExists(atPath: $0.1.path) }) else {
            throw ProjectRepositoryError.missingContent
        }

        var failures: [String] = []
        for (source, url) in candidates where fileManager.fileExists(atPath: url.path) {
            do {
                let decoded = try JSONDecoder().decode(ProjectContent.self, from: Data(contentsOf: url))
                var content = resolvingMediaURLs(in: decoded, projectID: projectID)
                let reconciledTitle = preferredTitle?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let titleChanged = reconciledTitle.map {
                    !$0.isEmpty && content.editorProject.title != $0
                } ?? false
                if titleChanged, let reconciledTitle {
                    content.editorProject.title = reconciledTitle
                }
                if source != .primary || titleChanged {
                    try? restorePrimary(content, projectID: projectID)
                }
                return ProjectLoadResult(content: content, source: source)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        throw ProjectRepositoryError.corruptedContent(failures.joined(separator: "; "))
    }

    func save(_ content: ProjectContent, projectID: UUID) throws {
        let folderURL = projectFolderURL(for: projectID)
        let contentURL = folderURL.appendingPathComponent("content.json")
        let backupURL = folderURL.appendingPathComponent("content.backup.json")
        let recoveryURL = folderURL.appendingPathComponent("content.recovery.json")
        let data = try JSONEncoder().encode(portableContent(content, projectID: projectID))

        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try data.write(to: recoveryURL, options: [.atomic])

            if fileManager.fileExists(atPath: contentURL.path) {
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
                try fileManager.copyItem(at: contentURL, to: backupURL)
                _ = try fileManager.replaceItemAt(
                    contentURL,
                    withItemAt: recoveryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: recoveryURL, to: contentURL)
            }
        } catch {
            throw ProjectRepositoryError.saveFailed(error.localizedDescription)
        }
    }

    private func contentURL(for projectID: UUID) -> URL {
        projectFolderURL(for: projectID).appendingPathComponent("content.json")
    }

    private func restorePrimary(_ content: ProjectContent, projectID: UUID) throws {
        let url = contentURL(for: projectID)
        let data = try JSONEncoder().encode(portableContent(content, projectID: projectID))
        try data.write(to: url, options: [.atomic])
    }

    private func portableContent(_ content: ProjectContent, projectID: UUID) -> ProjectContent {
        var project = content.editorProject
        let folderURL = projectFolderURL(for: projectID)
        for (mediaID, originalAsset) in project.mediaLibrary {
            var asset = originalAsset
            if asset.url.deletingLastPathComponent() == folderURL {
                asset.url = URL(fileURLWithPath: asset.fileName)
            }
            if var artifact = asset.backgroundRemovalArtifact,
                artifact.url.deletingLastPathComponent() == folderURL
            {
                artifact.url = URL(fileURLWithPath: artifact.url.lastPathComponent)
                asset.backgroundRemovalArtifact = artifact
            }
            project.mediaLibrary[mediaID] = asset
        }
        return ProjectContent(editorProject: project)
    }

    private func resolvingMediaURLs(in content: ProjectContent, projectID: UUID) -> ProjectContent {
        var project = content.editorProject
        let folderURL = projectFolderURL(for: projectID)
        for (mediaID, originalAsset) in project.mediaLibrary {
            var asset = originalAsset
            if !fileManager.fileExists(atPath: asset.url.path) {
                let candidate = folderURL.appendingPathComponent(asset.fileName)
                if fileManager.fileExists(atPath: candidate.path) {
                    asset.url = candidate
                }
            }
            if var artifact = asset.backgroundRemovalArtifact,
                !fileManager.fileExists(atPath: artifact.url.path)
            {
                let candidate = folderURL.appendingPathComponent(artifact.url.lastPathComponent)
                if fileManager.fileExists(atPath: candidate.path) {
                    artifact.url = candidate
                    asset.backgroundRemovalArtifact = artifact
                }
            }
            project.mediaLibrary[mediaID] = asset
        }
        return ProjectContent(editorProject: project)
    }

    private func projectFolderURL(for projectID: UUID) -> URL {
        rootURL.appendingPathComponent("project_\(projectID.uuidString)", isDirectory: true)
    }
}
