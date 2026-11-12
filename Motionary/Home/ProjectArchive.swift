// A streaming, versioned container for sharing an editable project and its files.
import Foundation

enum ProjectArchive {
    private static let magic = Data("MOTIONARYPROJECT1".utf8)
    private struct Entry: Codable {
        let path: String
        let size: UInt64
    }
    private struct Manifest: Codable {
        let content: ProjectContent
        let files: [Entry]
    }
    private enum ArchiveError: LocalizedError {
        case invalid, missing(String)
        var errorDescription: String? {
            switch self {
            case .invalid: return "This is not a valid Motionary project file."
            case .missing(let name): return "The project file is missing required media: \(name)"
            }
        }
    }

    static func export(project: Project, content: ProjectContent, folder: URL) throws -> URL {
        let fm = FileManager.default
        var files: [(String, URL)] = []
        if let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let path = String(url.path.dropFirst(folder.path.count + 1))
                if ["content.json", "content.backup.json", "content.recovery.json"].contains(path) { continue }
                files.append((path, url))
            }
        }
        var portable = content
        let shapeOnlyIDs = shapeOnlyMediaIDs(in: portable.editorProject)
        for (id, original) in portable.editorProject.mediaLibrary {
            var asset = original
            if shapeOnlyIDs.contains(id) {
                // Older projects can contain file-URL placeholders for generated shapes.
                asset.url = URL(string: "motionary-generated://shape/\(id.rawValue.uuidString)")!
                asset.backgroundRemovalArtifact = nil
                portable.editorProject.mediaLibrary[id] = asset
                continue
            }
            let source = try archiveFile(for: asset.url, name: asset.fileName, files: &files)
            asset.fileName = source
            asset.url = URL(fileURLWithPath: "/" + source)
            if var artifact = asset.backgroundRemovalArtifact {
                let name = try archiveFile(for: artifact.url, name: artifact.url.lastPathComponent, files: &files)
                artifact.url = URL(fileURLWithPath: "/" + name)
                asset.backgroundRemovalArtifact = artifact
            }
            portable.editorProject.mediaLibrary[id] = asset
        }
        files.sort { $0.0 < $1.0 }
        let entries = try files.map { path, url in
            Entry(path: path, size: (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0)
        }
        let manifest = try JSONEncoder().encode(Manifest(content: portable, files: entries))
        guard manifest.count <= 16 * 1024 * 1024 else { throw ArchiveError.invalid }
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = project.title.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let output = directory.appendingPathComponent(name.isEmpty ? "Project.mpj" : "\(name).mpj")
        do {
            guard fm.createFile(atPath: output.path, contents: nil) else { throw ArchiveError.invalid }
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            try handle.write(contentsOf: magic)
            var length = UInt64(manifest.count).bigEndian
            try withUnsafeBytes(of: &length) { try handle.write(contentsOf: Data($0)) }
            try handle.write(contentsOf: manifest)
            for (index, file) in files.enumerated() {
                let input = try FileHandle(forReadingFrom: file.1)
                do {
                    defer { try? input.close() }
                    try copy(input, handle, count: entries[index].size)
                }
            }
            return output
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    static func extract(url: URL, to folder: URL, projectID: UUID) throws -> ProjectContent {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        guard try read(input, count: magic.count) == magic else { throw ArchiveError.invalid }
        let lengthData = try read(input, count: 8)
        let length = lengthData.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length <= 16 * 1024 * 1024 else { throw ArchiveError.invalid }
        let manifest = try JSONDecoder().decode(Manifest.self, from: read(input, count: Int(length)))
        guard manifest.files.count <= 100_000 else { throw ArchiveError.invalid }
        var paths = Set<String>()
        for entry in manifest.files {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  paths.insert(entry.path).inserted else { throw ArchiveError.invalid }
            let destination = folder.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw ArchiveError.invalid }
            let output = try FileHandle(forWritingTo: destination)
            do {
                defer { try? output.close() }
                try copy(input, output, count: entry.size)
            }
        }
        guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw ArchiveError.invalid }
        var content = manifest.content
        content.editorProject.id = projectID
        let shapeOnlyIDs = shapeOnlyMediaIDs(in: content.editorProject)
        for (id, original) in content.editorProject.mediaLibrary {
            var asset = original
            if shapeOnlyIDs.contains(id) {
                asset.url = URL(string: "motionary-generated://shape/\(id.rawValue.uuidString)")!
                asset.backgroundRemovalArtifact = nil
                content.editorProject.mediaLibrary[id] = asset
                continue
            }
            guard paths.contains(asset.fileName) else { throw ArchiveError.missing(asset.fileName) }
            asset.url = folder.appendingPathComponent(asset.fileName)
            if var artifact = asset.backgroundRemovalArtifact {
                let name = artifact.url.lastPathComponent
                guard paths.contains(name) else { throw ArchiveError.missing(name) }
                artifact.url = folder.appendingPathComponent(name)
                asset.backgroundRemovalArtifact = artifact
            }
            content.editorProject.mediaLibrary[id] = asset
        }
        return content
    }

    private static func shapeOnlyMediaIDs(in project: EditorProject) -> Set<MediaID> {
        var shapes = Set<MediaID>()
        var media = Set<MediaID>()
        for track in project.tracks + project.sequences.values.flatMap(\.tracks) {
            for item in track.items {
                switch item {
                case .shape(let shape): shapes.insert(shape.mediaID)
                case .media(let item): media.insert(item.mediaID)
                default: break
                }
            }
        }
        return shapes.subtracting(media)
    }

    /// Resolve the same actual file the editor uses, while recovering old UUID-only
    /// filenames only when they identify exactly one file in the project folder.
    private static func archiveFile(
        for url: URL, name: String, files: inout [(String, URL)]
    ) throws -> String {
        let source: URL
        if url.isFileURL, FileManager.default.fileExists(atPath: url.path),
           (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            source = url
        } else if let match = files.first(where: { $0.0 == name }) {
            return match.0
        } else {
            let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            let candidates = files.filter {
                URL(fileURLWithPath: $0.0).deletingPathExtension().lastPathComponent == stem
            }
            guard UUID(uuidString: stem) != nil, candidates.count == 1,
                  let candidate = candidates.first else { throw ArchiveError.missing(name) }
            source = candidate.1
        }
        if let existing = files.first(where: { $0.1.standardizedFileURL == source.standardizedFileURL }),
           !existing.0.contains("/") { return existing.0 }
        // External and nested media need a unique top-level name on import.
        let ext = source.pathExtension
        let target = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        files.append((target, source))
        return target
    }

    private static func read(_ handle: FileHandle, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            let chunk = try handle.read(upToCount: count - result.count) ?? Data()
            guard !chunk.isEmpty else { throw ArchiveError.invalid }
            result.append(chunk)
        }
        return result
    }
    private static func copy(_ input: FileHandle, _ output: FileHandle, count: UInt64) throws {
        var remaining = count
        while remaining > 0 {
            let chunk = try read(input, count: Int(min(remaining, 1024 * 1024)))
            try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
    }
}
