import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let motionaryProject = UTType(exportedAs: MotionaryShareInbox.projectType)
}

enum MotionaryShareInbox {
    static let projectType = "com.moysoft.motionary.project"
    private static let appGroup = "group.com.moysoft.motionary"
    private static let archiveSignature = Data("MOTIONARYPROJECT1".utf8)

    struct FailedToQueue: LocalizedError {
        var errorDescription: String? { "The project couldn’t be sent to Motionary." }
    }

    private static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Project Imports", isDirectory: true)
    }

    static func queueProject(at url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.read(upToCount: archiveSignature.count) == archiveSignature,
            let directory
        else { throw FailedToQueue() }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
        let staging = destination.appendingPathExtension("partial")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: url, to: staging)
        try fileManager.moveItem(at: staging, to: destination.appendingPathExtension("mpj"))
    }

    static func pendingProjects() -> [URL] {
        guard let directory else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []).filter { $0.pathExtension == "mpj" }
    }
}
