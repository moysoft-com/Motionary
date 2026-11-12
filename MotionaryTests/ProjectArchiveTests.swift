import XCTest
import UIKit
@testable import Motionary

final class ProjectArchiveTests: XCTestCase {
    func testRoundTripCopiesMediaAndAssignsNewProjectID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = source.appendingPathComponent("clip.mov")
        try Data("media bytes".utf8).write(to: media)
        let mediaID = MediaID()
        let asset = MediaAsset(id: mediaID, source: ClipSource(id: mediaID.rawValue, url: media, mediaType: .video, originalDuration: 1, naturalSize: nil))
        var editor = EditorProject.empty(title: "Test")
        editor.mediaLibrary[mediaID] = asset
        let clip = TimelineClip(name: "clip", source: asset.source, timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 1))
        editor.tracks[0].appendLegacyClip(clip)
        let archive = try ProjectArchive.export(project: Project(title: "Test"), content: ProjectContent(editorProject: editor), folder: source)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let newID = UUID()
        let imported = try ProjectArchive.extract(url: archive, to: destination, projectID: newID)
        XCTAssertEqual(imported.editorProject.id, newID)
        XCTAssertEqual(imported.editorProject.mediaLibrary[mediaID]?.url, destination.appendingPathComponent("clip.mov"))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("clip.mov")), Data("media bytes".utf8))
    }

    func testRoundTripPreservesGeneratedShapesWithoutMediaFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mediaID = MediaID()
        let generatedURL = URL(string: "motionary-generated://shape/\(mediaID.rawValue.uuidString)")!
        let asset = MediaAsset(id: mediaID, source: ClipSource(
            id: mediaID.rawValue, url: generatedURL, mediaType: .image, originalDuration: 5
        ))
        let shape = ShapeTimelineItem(
            name: "Rectangle", mediaID: mediaID, shape: ClipShape(kind: .rectangle),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 5)
        )
        let editor = EditorProject(
            title: "Shapes", mediaLibrary: [mediaID: asset],
            tracks: [TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])]
        )
        let archive = try ProjectArchive.export(
            project: Project(title: "Shapes"), content: ProjectContent(editorProject: editor), folder: source
        )
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let imported = try ProjectArchive.extract(url: archive, to: destination, projectID: UUID())
        XCTAssertEqual(imported.editorProject.mediaLibrary[mediaID]?.url, generatedURL)
        guard case .shape(let importedShape) = imported.editorProject.tracks.first?.items.first else {
            return XCTFail("Shape was not preserved")
        }
        XCTAssertEqual(importedShape, shape)
    }

    func testLegacyShapePlaceholderSurvivesRepositoryArchiveRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = UUID()
        let folder = root.appendingPathComponent("project_\(projectID.uuidString)")
        let mediaID = MediaID()
        let shape = ShapeTimelineItem(
            name: mediaID.rawValue.uuidString, mediaID: mediaID, shape: ClipShape(kind: .rectangle),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 5)
        )
        let editor = EditorProject(title: "Legacy", tracks: [
            TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])
        ])
        XCTAssertTrue(editor.mediaLibrary[mediaID]!.url.isFileURL)
        let repository = ProjectRepository(rootURL: root)
        try await repository.save(ProjectContent(editorProject: editor), projectID: projectID)
        let loaded = try await repository.load(projectID: projectID).content
        let archive = try ProjectArchive.export(project: Project(title: "Legacy"), content: loaded, folder: folder)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let newID = UUID()
        let importedFolder = root.appendingPathComponent("project_\(newID.uuidString)")
        let imported = try ProjectArchive.extract(url: archive, to: importedFolder, projectID: newID)
        try await repository.save(imported, projectID: newID)
        let reloaded = try await repository.load(projectID: newID).content
        XCTAssertEqual(reloaded.editorProject.mediaLibrary[mediaID]?.url.scheme, "motionary-generated")
        guard case .shape = reloaded.editorProject.tracks.first?.items.first else { return XCTFail("Shape missing") }
    }

    func testExternalMediaAndLegacyFilenameAreIncluded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("external.mov")
        try Data("external".utf8).write(to: external)
        let stem = UUID().uuidString
        try Data("local".utf8).write(to: folder.appendingPathComponent("\(stem).mov"))
        let externalSource = ClipSource(url: external, mediaType: .video, originalDuration: 1)
        let oldSource = ClipSource(url: folder.appendingPathComponent(stem), mediaType: .video, originalDuration: 1)
        let clips = [externalSource, oldSource].map {
            TimelineClip(name: $0.url.lastPathComponent, source: $0, timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 1))
        }
        let editor = EditorProject(title: "Media", tracks: [TimelineTrack(name: "Video", kind: .visual, clips: clips)])
        let archive = try ProjectArchive.export(project: Project(title: "Media"), content: ProjectContent(editorProject: editor), folder: folder)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let imported = try ProjectArchive.extract(url: archive, to: root.appendingPathComponent("imported"), projectID: UUID())
        let values = try imported.editorProject.mediaLibrary.values.map { try Data(contentsOf: $0.url) }
        XCTAssertEqual(Set(values), Set([Data("external".utf8), Data("local".utf8)]))
    }

    func testMediaInCompoundSequenceSurvivesArchiveRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaURL = root.appendingPathComponent("clip.mov")
        try Data("sequence".utf8).write(to: mediaURL)
        let source = ClipSource(url: mediaURL, mediaType: .video, originalDuration: 1)
        let clip = TimelineClip(name: "clip", source: source, timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 1))
        let sequence = CompoundSequence(name: "Nested", tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])])
        let editor = EditorProject(title: "Nested", sequences: [sequence.id: sequence])
        XCTAssertNotNil(editor.mediaLibrary[clip.mediaID])
        let archive = try ProjectArchive.export(project: Project(title: "Nested"), content: ProjectContent(editorProject: editor), folder: root)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let imported = try ProjectArchive.extract(url: archive, to: root.appendingPathComponent("imported"), projectID: UUID())
        let asset = try XCTUnwrap(imported.editorProject.mediaLibrary[clip.mediaID])
        XCTAssertEqual(try Data(contentsOf: asset.url), Data("sequence".utf8))
    }

    func testAmbiguousLegacyFilenameIsNotGuessed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stem = UUID().uuidString
        try Data("one".utf8).write(to: folder.appendingPathComponent("\(stem).mov"))
        try Data("two".utf8).write(to: folder.appendingPathComponent("\(stem).mp4"))
        let source = ClipSource(url: folder.appendingPathComponent(stem), mediaType: .video, originalDuration: 1)
        let clip = TimelineClip(name: stem, source: source, timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 1))
        let editor = EditorProject(title: "Ambiguous", tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])])
        XCTAssertThrowsError(try ProjectArchive.export(project: Project(title: "Ambiguous"), content: ProjectContent(editorProject: editor), folder: folder))
    }

    func testExportRejectsMissingRealMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ClipSource(url: root.appendingPathComponent("missing.mov"), mediaType: .video, originalDuration: 1)
        let clip = TimelineClip(name: "Missing", source: source, timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 1))
        let editor = EditorProject(title: "Missing", tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [clip])])
        XCTAssertThrowsError(try ProjectArchive.export(project: Project(title: "Missing"), content: ProjectContent(editorProject: editor), folder: root))
    }

    @MainActor
    func testImportedProjectGetsRenderedPoster() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shape = ShapeTimelineItem(name: "Overlay", mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle, color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1), width: 80, height: 80),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 1))
        let editor = EditorProject(title: "Imported poster", renderSettings: RenderSettings(width: 100, height: 100, frameRate: 30),
            tracks: [TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])])
        let archive = try ProjectArchive.export(project: Project(title: editor.title), content: ProjectContent(editorProject: editor), folder: source)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let store = ProjectStore()
        let id = UUID()
        defer { store.deleteProject(with: id) }
        let imported = try ProjectArchive.extract(url: archive, to: store.projectFolderURL(for: id), projectID: id)
        try await store.repository.save(imported, projectID: id)
        store.recordSavedContent(imported, projectID: id)
        store.schedulePosterRender(for: imported.editorProject, projectID: id)
        for _ in 0..<100 where store.existingPosterURL(for: id) == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        let poster = try XCTUnwrap(store.existingPosterURL(for: id))
        XCTAssertNotNil(UIImage(data: try Data(contentsOf: poster)))
    }

    func testRejectsTruncatedArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("broken.mpj")
        try Data("MOTIONARYPROJECT1".utf8).write(to: archive)
        XCTAssertThrowsError(try ProjectArchive.extract(url: archive, to: root.appendingPathComponent("out"), projectID: UUID()))
    }
}
