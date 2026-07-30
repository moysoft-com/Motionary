// Observable editor state and dependency ownership. Behavior is organized in focused extensions.

import AVFoundation
import Combine
import SwiftUI

enum EditorAnalysisKind: String, Equatable {
    case backgroundRemoval
    case audioBeats

    var title: String {
        switch self {
        case .backgroundRemoval: "Removing background"
        case .audioBeats: "Analyzing beats"
        }
    }
}

struct EditorAnalysisState: Equatable {
    var kind: EditorAnalysisKind
    var progress: Double
    var blocksEditor: Bool = true
}

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
    var selectedTimelineItemID: UUID? {
        get { selectedClipID }
        set { selectedClipID = newValue }
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
    var previewProgress: Double {
        get { previewState.progress }
        set { previewState.progress = min(max(newValue, 0), 1) }
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
    @Published private(set) var effectRenderDiagnostics: [EffectRenderDiagnostic] = []
    @Published var analysisState: EditorAnalysisState?
    @Published var invalidBackgroundRemovalMediaIDs: Set<MediaID> = []
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
    @Published var liveTextPreviewID: UUID?
    @Published var isRippleEditingEnabled = false

    let projectID: UUID
    let projectStore: ProjectStore
    let renderService = CompositionRenderService()
    let importService = MediaImportService()
    let exportService = VideoExportService()
    var timeObserver: Any?
    var previewVideoOutput: AVPlayerItemVideoOutput?
    var effectRenderDiagnosticsHandlerToken: UUID?
    var wasPlayingBeforeScrub = false
    var undoStack: [AnyEditorCommand] = []
    var redoStack: [AnyEditorCommand] = []
    var rebuildTask: Task<Void, Never>?
    var previewGeneration = 0
    var previewQuality: PreviewQuality = .balanced
    var scrubSeekTask: Task<Void, Never>?
    var importTask: Task<Void, Never>?
    var exportTask: Task<Void, Never>?
    var analysisTask: Task<Void, Never>?
    var toastTask: Task<Void, Never>?
    var autosaveTask: Task<Void, Never>?
    var projectPosterTask: Task<Void, Never>?
    var lastProjectPosterSignature: Data?
    var interactivePreviewThrottleTask: Task<Void, Never>?
    var livePreviewFrameRefreshTask: Task<Void, Never>?
    var livePreviewOverrideClearTask: Task<Void, Never>?
    var lastInteractivePreviewRebuild: CFAbsoluteTime = 0
    var lastLivePreviewFrameRefresh: CFAbsoluteTime = 0
    var livePreviewFrameRefreshInFlight = false
    var pendingInteractivePreviewInvalidation: EditorInvalidation = []
    var pendingLivePreviewFrameRefresh = false
    var pendingScrubSeekTime: Double?
    var isScrubSeekInFlight = false
    var lastIssuedScrubSeekTime: Double?
    var scrubSeekLatencyEstimate: CFTimeInterval = 0
    var scrubSessionGeneration = 0
    var scrubSeekGeneration = 0
    var livePreviewInteractionGeneration = 0
    var playbackCommandGeneration = 0
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
    var lastPlayableTime: Double {
        guard duration > 0 else { return 0 }
        let frameDuration = 1 / Double(max(project.renderSettings.frameRate, 1))
        return max(duration - frameDuration, 0)
    }

    func clampedTimelineTime(_ time: Double) -> Double {
        min(max(time, 0), duration)
    }

    func clampedPlayableTime(_ time: Double) -> Double {
        min(max(time, 0), lastPlayableTime)
    }

    var longRunningTaskTitle: String? {
        if isExporting {
            return "Exporting \(Int(exportProgress * 100))%"
        }
        if isImporting {
            return "Importing"
        }
        if let analysisState {
            return "\(analysisState.kind.title) \(Int(analysisState.progress * 100))%"
        }
        if isInitialPreviewLoadBlocking {
            return "Preparing preview \(Int(previewProgress * 100))%"
        }
        return nil
    }

    var isPerformingLongTask: Bool {
        longRunningTaskTitle != nil
    }

    var shouldPresentBusyOverlay: Bool {
        if let analysisState {
            return analysisState.blocksEditor
        }
        return isExporting || isImporting || isInitialPreviewLoadBlocking
    }

    var isInitialPreviewLoadBlocking: Bool {
        isRenderingPreview && previewContentRevision == 0
    }
    var canExportVideo: Bool {
        project.tracks.contains { track in
            !track.isMuted
                && (track.kind == .visual || track.kind == .shape || track.kind == .text)
                && track.items.contains { item in
                    switch item {
                    case .media(let media):
                        media.mediaType != .audio
                    case .shape, .text:
                        true
                    case .caption, .adjustment, .compound:
                        false
                    }
                }
        }
    }

    var selectedClip: TimelineClip? {
        guard selectedClipID != nil else { return nil }
        return selectedTimelineItem?.legacyClip()
    }

    var selectedTimelineItem: TimelineItem? {
        guard let selectedClipID else { return nil }
        return project.item(id: selectedClipID)
    }

    var selectedClipIsActiveAtPlayhead: Bool {
        guard let item = selectedTimelineItem else { return false }
        return currentTime >= item.timelineStart && currentTime < item.timelineEnd
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
        playbackState.$currentTime
            .map { [weak self] currentTime in
                guard let item = self?.selectedTimelineItem else { return false }
                return currentTime >= item.timelineStart && currentTime < item.timelineEnd
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
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
        installEffectRenderDiagnosticsHandler()
    }

    deinit {
        if let effectRenderDiagnosticsHandlerToken {
            EffectRenderDiagnostics.shared.removeHandler(effectRenderDiagnosticsHandlerToken)
        }
    }

    func installEffectRenderDiagnosticsHandler() {
        guard effectRenderDiagnosticsHandlerToken == nil else { return }
        effectRenderDiagnosticsHandlerToken = EffectRenderDiagnostics.shared.installHandler {
            [weak self] diagnostic in
            Task { @MainActor [weak self] in
                self?.recordEffectRenderDiagnostic(diagnostic)
            }
        }
    }

    func removeEffectRenderDiagnosticsHandler() {
        guard let token = effectRenderDiagnosticsHandlerToken else { return }
        effectRenderDiagnosticsHandlerToken = nil
        EffectRenderDiagnostics.shared.removeHandler(token)
    }

    private func recordEffectRenderDiagnostic(_ diagnostic: EffectRenderDiagnostic) {
        guard !effectRenderDiagnostics.contains(diagnostic) else { return }
        effectRenderDiagnostics.append(diagnostic)
        let overflow = effectRenderDiagnostics.count - 32
        if overflow > 0 {
            effectRenderDiagnostics.removeFirst(overflow)
        }
    }
}
