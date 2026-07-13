// Observable editor state and dependency ownership. Behavior is organized in focused extensions.

import AVFoundation
import Combine
import SwiftUI

@MainActor
/// Coordinates all editor state transitions and delegates media, rendering, export, and persistence work to services.
final class EditorViewModel: ObservableObject {
    let playbackState = PlaybackState()
    let selectionState = SelectionState()
    let timelineState = TimelineState()
    let previewState = PreviewState()
    let exportState = ExportState()
    let projectSession = ProjectSession()

    @Published var project: EditorProject
    @Published var player: AVPlayer?
    var currentTime: Double {
        get { playbackState.currentTime }
        set { playbackState.currentTime = newValue }
    }
    var selectedClipID: UUID? {
        get { selectionState.clipID }
        set { selectionState.clipID = newValue }
    }
    var selectedTrackID: UUID? {
        get { selectionState.trackID }
        set { selectionState.trackID = newValue }
    }
    var isPlaying: Bool {
        get { playbackState.isPlaying }
        set { playbackState.isPlaying = newValue }
    }
    var isScrubbing: Bool {
        get { playbackState.isScrubbing }
        set { playbackState.isScrubbing = newValue }
    }
    @Published var isImporting = false
    var isRenderingPreview: Bool {
        get { previewState.isBuilding }
        set {
            if newValue, !previewState.isBuilding {
                previewState.status = .building(generation: previewGeneration)
            } else if !newValue, previewState.isBuilding {
                previewState.status = .idle
            }
        }
    }
    var previewContentRevision: Int {
        get { previewState.contentRevision }
        set { previewState.contentRevision = newValue }
    }
    var isExporting: Bool {
        get { exportState.isExporting }
        set { exportState.isExporting = newValue }
    }
    var exportProgress: Double {
        get { exportState.progress }
        set { exportState.progress = newValue }
    }
    @Published var confirmationMessage: String?
    @Published var errorMessage: String?
    var timelineContentRevision: Int {
        get { timelineState.contentRevision }
        set { timelineState.contentRevision = newValue }
    }
    var canUndo: Bool {
        get { timelineState.canUndo }
        set { timelineState.canUndo = newValue }
    }
    var canRedo: Bool {
        get { timelineState.canRedo }
        set { timelineState.canRedo = newValue }
    }
    @Published var activeKeyframeTarget: KeyframeTarget?
    @Published var selectedKeyframeID: UUID?
    @Published var graphSegment: KeyframeSegment?
    @Published var displayedGraphSegment: KeyframeSegment?
    @Published var isRippleEditingEnabled = false

    let projectID: UUID
    let projectStore: ProjectStore
    let renderService = CompositionRenderService()
    let importService = MediaImportService()
    let exportService = VideoExportService()
    var timeObserver: Any?
    var wasPlayingBeforeScrub = false
    var undoStack: [AnyEditorCommand] = []
    var redoStack: [AnyEditorCommand] = []
    var rebuildTask: Task<Void, Never>?
    var previewGeneration = 0
    var previewQuality: PreviewQuality = .balanced
    var scrubSeekTask: Task<Void, Never>?
    var importTask: Task<Void, Never>?
    var exportTask: Task<Void, Never>?
    var toastTask: Task<Void, Never>?
    var autosaveTask: Task<Void, Never>?
    var pendingScrubSeekTime: Double?
    var isScrubSeekInFlight = false
    var interactiveEditSnapshot: EditorProject?
    var timelineClipCache: [UUID: [TimelineClip]] = [:]
    var timelineClipCacheRevision = -1
    var timelineSnapshot: TimelineRenderSnapshot?
    var timelineSnapshotToken: (revision: Int, selectedClipID: UUID?) = (-1, nil)
    var deferredPreviewInvalidation: EditorInvalidation = []
    var lastScrubUIUpdate: CFAbsoluteTime = 0
    var stateCancellables: Set<AnyCancellable> = []
    let clipRevealEpsilon = 0.01

    var duration: Double { project.duration }
    var longRunningTaskTitle: String? {
        if isExporting {
            return "Exporting \(Int(exportProgress * 100))%"
        }
        if isImporting {
            return "Importing"
        }
        return nil
    }

    var isPerformingLongTask: Bool {
        longRunningTaskTitle != nil
    }
    var canExportVideo: Bool {
        project.tracks.contains { track in
            (track.kind == .visual || track.kind == .shape)
                && track.clips.contains { $0.mediaType != .audio }
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
        self.selectionState.trackID =
            initialContent.editorProject.tracks.first(where: { $0.kind == .visual })?.id
            ?? initialContent.editorProject.tracks.first?.id
        selectionState.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &stateCancellables)
        timelineState.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &stateCancellables)
        previewState.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &stateCancellables)
        projectSession.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &stateCancellables)
        exportState.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &stateCancellables)
    }
}
