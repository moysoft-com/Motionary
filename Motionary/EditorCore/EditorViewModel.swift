// Observable editor state and dependency ownership. Behavior is organized in focused extensions.

import AVFoundation
import SwiftUI

@MainActor
/// Coordinates all editor state transitions and delegates media, rendering, export, and persistence work to services.
final class EditorViewModel: ObservableObject {
    @Published var project: EditorProject
    @Published var player: AVPlayer?
    @Published var currentTime: Double = 0
    @Published var selectedClipID: UUID?
    @Published var selectedTrackID: UUID?
    @Published var isPlaying = false
    @Published var isScrubbing = false
    @Published var isImporting = false
    @Published var isRenderingPreview = false
    @Published var isExporting = false
    @Published var exportProgress = 0.0
    @Published var confirmationMessage: String?
    @Published var errorMessage: String?
    @Published var timelineContentRevision = 0
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var isAutoKeyEnabled = false
    @Published var activeKeyframeTarget: KeyframeTarget?
    @Published var selectedKeyframeID: UUID?
    @Published var graphSegment: KeyframeSegment?

    let projectID: UUID
    let projectStore: ProjectStore
    let renderService = CompositionRenderService()
    let importService = MediaImportService()
    let exportService = VideoExportService()
    var timeObserver: Any?
    var wasPlayingBeforeScrub = false
    var undoStack: [EditorProject] = []
    var redoStack: [EditorProject] = []
    var rebuildTask: Task<Void, Never>?
    var scrubSeekTask: Task<Void, Never>?
    var importTask: Task<Void, Never>?
    var toastTask: Task<Void, Never>?
    var pendingScrubSeekTime: Double?
    var interactiveEditSnapshot: EditorProject?
    let clipRevealEpsilon = 0.01

    var duration: Double { project.duration }
    var canExportVideo: Bool {
        project.tracks.contains { track in
            track.kind == .visual && track.clips.contains { $0.mediaType != .audio }
        }
    }

    var selectedClip: TimelineClip? {
        guard let selectedClipID else { return nil }
        return project.tracks.flatMap(\.clips).first { $0.id == selectedClipID }
    }

    var selectedClipIsActiveAtPlayhead: Bool {
        guard let selectedClip else { return false }
        return isTimeInside(selectedClip)
    }

    init(projectID: UUID, projectStore: ProjectStore, initialContent: ProjectContent) {
        self.projectID = projectID
        self.projectStore = projectStore
        self.project = initialContent.editorProject
        self.selectedTrackID =
            initialContent.editorProject.tracks.first(where: { $0.kind == .visual })?.id
            ?? initialContent.editorProject.tracks.first?.id
    }
}
