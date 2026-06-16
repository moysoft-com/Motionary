import AVFoundation
import PhotosUI
import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case media = "Media"
    case edit = "Edit"
    case transform = "Transform"
    case motion = "Motion"
    case effects = "Effects"
    case adjust = "Adjust"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .media:
            "photo.on.rectangle.angled"
        case .edit:
            "timeline.selection"
        case .transform:
            "crop.rotate"
        case .motion:
            "point.3.connected.trianglepath.dotted"
        case .effects:
            "sparkles"
        case .adjust:
            "slider.horizontal.3"
        }
    }
}

enum KeyframeTarget {
    case positionX
    case positionY
    case scale
    case rotation
    case opacity
    case brightness
    case contrast
    case saturation
    case exposure
    case effect(UUID)
}

struct TimelinePlacementResult {
    var start: Double
    var trackIndex: Int
    var snapped: Bool
}

struct TimelineTrimResult {
    var edgeTime: Double
    var appliedDelta: Double
    var snapped: Bool
}

struct CanvasRatioPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let width: Int
    let height: Int

    var settings: RenderSettings {
        RenderSettings(width: width, height: height)
    }

    func settings(frameRate: Int32) -> RenderSettings {
        RenderSettings(width: width, height: height, frameRate: frameRate)
    }

    static let presets: [CanvasRatioPreset] = [
        CanvasRatioPreset(id: "9:16", title: "9:16", width: 1080, height: 1920),
        CanvasRatioPreset(id: "1:1", title: "1:1", width: 1080, height: 1080),
        CanvasRatioPreset(id: "16:9", title: "16:9", width: 1920, height: 1080),
        CanvasRatioPreset(id: "4:5", title: "4:5", width: 1080, height: 1350)
    ]
}

@MainActor
final class EditorViewModel: ObservableObject {
    @Published var project: EditorProject
    @Published var player: AVPlayer?
    @Published var currentTime: Double = 0
    @Published var selectedClipID: UUID?
    @Published var selectedTrackID: UUID?
    @Published var selectedTool: EditorTool = .media
    @Published var isPlaying = false
    @Published var isScrubbing = false
    @Published var isImporting = false
    @Published var isRenderingPreview = false
    @Published var isExporting = false
    @Published var exportProgress = 0.0
    @Published var shareURL: URL?
    @Published var errorMessage: String?
    @Published private(set) var timelineContentRevision = 0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private let projectID: UUID
    private let projectStore: ProjectStore
    private let renderService = CompositionRenderService()
    private let importService = MediaImportService()
    private let exportService = VideoExportService()
    private var timeObserver: Any?
    private var wasPlayingBeforeScrub = false
    private var undoStack: [EditorProject] = []
    private var redoStack: [EditorProject] = []
    private var rebuildTask: Task<Void, Never>?
    private var scrubSeekTask: Task<Void, Never>?
    private var pendingScrubSeekTime: Double?
    private var interactiveEditSnapshot: EditorProject?
    private let clipRevealEpsilon = 0.01

    var duration: Double { project.duration }

    var selectedClip: TimelineClip? {
        guard let selectedClipID else { return nil }
        return project.tracks.flatMap(\.clips).first { $0.id == selectedClipID }
    }

    var selectedTrack: TimelineTrack? {
        guard let selectedTrackID else { return nil }
        return project.tracks.first { $0.id == selectedTrackID }
    }

    init(projectID: UUID, projectStore: ProjectStore, initialContent: ProjectContent) {
        self.projectID = projectID
        self.projectStore = projectStore
        self.project = initialContent.editorProject
        self.selectedTrackID = initialContent.editorProject.tracks.first(where: { $0.kind == .visual })?.id
    }

    func start() {
        EditorAudioSession.configurePlayback()
        repairStoredMediaReferences()
        schedulePreviewRebuild(seekTo: 0, delay: false)
        persist()
    }

    func stop() {
        rebuildTask?.cancel()
        rebuildTask = nil
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        pendingScrubSeekTime = nil
        isRenderingPreview = false
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player?.pause()
        player = nil
        isPlaying = false
    }

    func togglePlayback() {
        guard let player else { return }
        if !isPlaying && currentTime >= duration {
            seek(to: 0)
        }

        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        project = previous
        selectedClipID = nil
        selectedTrackID = project.tracks.first(where: { $0.kind == .visual })?.id
        incrementTimelineContentRevision()
        updateHistoryFlags()
        persist()
        schedulePreviewRebuild(seekTo: min(currentTime, duration))
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        selectedClipID = nil
        selectedTrackID = project.tracks.first(where: { $0.kind == .visual })?.id
        incrementTimelineContentRevision()
        updateHistoryFlags()
        persist()
        schedulePreviewRebuild(seekTo: min(currentTime, duration))
    }

    func seek(to time: Double, exact: Bool = true) {
        let clamped = min(max(time, 0), max(duration, 0))
        updateCurrentTime(clamped)
        seekPlayer(to: clamped, exact: exact)
    }

    private func seekPlayer(to time: Double, exact: Bool) {
        let tolerance = exact ? CMTime.zero : CMTime(seconds: 0.035, preferredTimescale: 600)
        player?.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    func beginScrub() {
        wasPlayingBeforeScrub = isPlaying
        player?.pause()
        isPlaying = false
        isScrubbing = true
    }

    func updateScrub(to time: Double) {
        let clamped = min(max(time, 0), max(duration, 0))
        updateCurrentTime(clamped)
        pendingScrubSeekTime = clamped
        guard scrubSeekTask == nil else { return }

        scrubSeekTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 35_000_000)
            await MainActor.run {
                guard let self else { return }
                let target = self.pendingScrubSeekTime
                self.pendingScrubSeekTime = nil
                self.scrubSeekTask = nil
                guard let target else { return }
                self.seekPlayer(to: target, exact: false)
            }
        }
    }

    func endScrub(at time: Double) {
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        pendingScrubSeekTime = nil
        seek(to: time, exact: true)
        isScrubbing = false
        wasPlayingBeforeScrub = false
    }

    func importPhotosItem(_ item: PhotosPickerItem?) {
        guard let item else { return }
        importPhotosItems([item])
    }

    func importPhotosItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            await setBusyImporting(true)
            do {
                for item in items {
                    let imported = try await importService.importPhotosItem(item, projectID: projectID, projectStore: projectStore)
                    addImportedMedia(imported, sequentialVisual: items.count > 1)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            await setBusyImporting(false)
        }
    }

    func importAudio(url: URL) {
        Task {
            await setBusyImporting(true)
            do {
                let imported = try await importService.importAudioFile(url, projectID: projectID, projectStore: projectStore)
                addImportedMedia(imported)
            } catch {
                errorMessage = error.localizedDescription
            }
            await setBusyImporting(false)
        }
    }

    func addVisualLayer() {
        mutateProject(rebuild: false) { project in
            let index = project.tracks.filter { $0.kind == .visual }.count + 1
            project.tracks.insert(TimelineTrack(name: "Layer \(index)", kind: .visual), at: 0)
            selectedTrackID = project.tracks.first?.id
        }
    }

    func addAudioTrack() {
        mutateProject(rebuild: false) { project in
            let index = project.tracks.filter { $0.kind == .audio }.count + 1
            project.tracks.append(TimelineTrack(name: "Audio \(index)", kind: .audio))
            selectedTrackID = project.tracks.last?.id
        }
    }

    func moveTrack(_ trackID: UUID, to proposedIndex: Int) {
        mutateProject(rebuild: false) { project in
            guard let sourceIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            let track = project.tracks[sourceIndex]
            let matchingIndices = project.tracks.indices.filter { project.tracks[$0].kind == track.kind }
            guard matchingIndices.count > 1 else { return }

            let boundedIndex = min(max(proposedIndex, matchingIndices.first ?? 0), matchingIndices.last ?? sourceIndex)
            guard project.tracks[boundedIndex].kind == track.kind, sourceIndex != boundedIndex else { return }

            project.tracks.remove(at: sourceIndex)
            let insertionIndex = boundedIndex > sourceIndex ? boundedIndex - 1 : boundedIndex
            project.tracks.insert(track, at: insertionIndex)
            project.renumberTracks()
            selectedTrackID = track.id
        }
    }

    func selectClip(_ clipID: UUID?, trackID: UUID? = nil, revealInPreview: Bool = false) {
        let resolvedTrackID: UUID?
        if let trackID {
            resolvedTrackID = trackID
        } else if let clipID,
                  let track = project.tracks.first(where: { $0.clips.contains { $0.id == clipID } }) {
            resolvedTrackID = track.id
        } else {
            resolvedTrackID = nil
        }

        updateSelection(clipID: clipID, trackID: resolvedTrackID)

        if revealInPreview, let clipID, let clip = project.clip(id: clipID), !isTimeInside(clip) {
            seek(to: nearestVisibleTime(for: clip), exact: true)
        }
    }

    func splitSelectedClip() {
        let targetID = selectedClipID ?? activeVisualClipID(at: currentTime)
        guard let targetID else { return }

        mutateProject { project in
            guard let location = project.clipLocation(id: targetID) else { return }
            let clip = project.tracks[location.track].clips[location.clip]
            let offset = currentTime - clip.timelineStart
            guard offset > 0.08, offset < clip.sourceRange.duration - 0.08 else { return }

            var first = clip
            first.sourceRange = TimeRangeValue(start: clip.sourceRange.start, duration: offset)

            var second = clip
            second.id = UUID()
            second.name = "\(clip.name) split"
            second.timelineStart = currentTime
            second.sourceRange = TimeRangeValue(
                start: clip.sourceRange.start + offset,
                duration: clip.sourceRange.duration - offset
            )

            project.tracks[location.track].clips[location.clip] = first
            project.tracks[location.track].clips.insert(second, at: location.clip + 1)
            selectedClipID = second.id
        }
    }

    func deleteSelectedClip() {
        guard let selectedClipID else { return }
        mutateProject { project in
            guard let location = project.clipLocation(id: selectedClipID) else { return }
            project.tracks[location.track].clips.remove(at: location.clip)
            self.selectedClipID = nil
        }
    }

    func duplicateSelectedClip() {
        guard let selectedClipID else { return }
        mutateProject { project in
            guard let location = project.clipLocation(id: selectedClipID) else { return }
            let sourceClip = project.tracks[location.track].clips[location.clip]
            var copy = sourceClip
            copy.id = UUID()
            copy.name = "\(sourceClip.name) copy"
            copy.timelineStart = project.resolvedPlacementStart(
                proposedStart: sourceClip.timelineEnd + 0.15,
                duration: sourceClip.sourceRange.duration,
                destinationTrackIndex: location.track,
                requiredKind: sourceClip.requiredTrackKind
            )
            project.tracks[location.track].clips.insert(copy, at: location.clip + 1)
            project.tracks[location.track].clips.sort { $0.timelineStart < $1.timelineStart }
            self.selectedClipID = copy.id
        }
    }

    func moveSelectedClip(by seconds: Double) {
        guard let selectedClipID else { return }
        mutateProject { project in
            guard let location = project.clipLocation(id: selectedClipID) else { return }
            var clip = project.tracks[location.track].clips.remove(at: location.clip)
            let placement = project.resolvedPlacement(
                proposedStart: clip.timelineStart + seconds,
                duration: clip.sourceRange.duration,
                destinationTrackIndex: location.track,
                requiredKind: clip.requiredTrackKind
            )
            clip.timelineStart = placement.start
            project.tracks[location.track].clips.append(clip)
            project.tracks[location.track].clips.sort { $0.timelineStart < $1.timelineStart }
        }
    }

    @discardableResult
    func placeClip(
        _ clipID: UUID,
        at timelineStart: Double,
        proposedTrackIndex: Int,
        insertTrackAt insertionIndex: Int? = nil,
        rebuild: Bool = true,
        interactive: Bool = false
    ) -> TimelinePlacementResult? {
        if interactive {
            beginInteractiveEdit()
        }

        var result: TimelinePlacementResult?
        mutateProject(
            rebuild: interactive ? false : rebuild,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive
        ) { project in
            guard let location = project.clipLocation(id: clipID) else { return }
            var clip = project.tracks[location.track].clips.remove(at: location.clip)
            let requiredKind = clip.requiredTrackKind
            let destinationIndex: Int
            if let insertionIndex {
                destinationIndex = project.insertCompatibleTrack(at: insertionIndex, requiredKind: requiredKind)
            } else {
                destinationIndex = project.compatibleTrackIndex(
                    proposedIndex: proposedTrackIndex,
                    requiredKind: requiredKind
                )
            }

            let placement = project.resolvedPlacement(
                proposedStart: timelineStart,
                duration: clip.sourceRange.duration,
                destinationTrackIndex: destinationIndex,
                requiredKind: requiredKind,
                snapAnchors: [currentTime]
            )
            clip.timelineStart = placement.start
            project.tracks[destinationIndex].clips.append(clip)
            project.tracks[destinationIndex].clips.sort { $0.timelineStart < $1.timelineStart }
            project.removeEmptyAutoTracks()
            project.renumberTracks()
            selectedClipID = clip.id
            selectedTrackID = project.tracks.first(where: { $0.clips.contains { $0.id == clip.id } })?.id
            result = TimelinePlacementResult(
                start: placement.start,
                trackIndex: project.clipLocation(id: clip.id)?.track ?? destinationIndex,
                snapped: placement.snapped
            )
        }
        return result
    }

    func previewClipPlacement(
        _ clipID: UUID,
        at timelineStart: Double,
        proposedTrackIndex: Int,
        insertTrackAt insertionIndex: Int? = nil
    ) -> TimelinePlacementResult? {
        var previewProject = project
        guard let location = previewProject.clipLocation(id: clipID) else { return nil }
        let clip = previewProject.tracks[location.track].clips.remove(at: location.clip)
        let requiredKind = clip.requiredTrackKind
        let destinationIndex: Int
        if let insertionIndex {
            destinationIndex = previewProject.insertCompatibleTrack(at: insertionIndex, requiredKind: requiredKind)
        } else {
            destinationIndex = previewProject.compatibleTrackIndex(
                proposedIndex: proposedTrackIndex,
                requiredKind: requiredKind
            )
        }
        let placement = previewProject.resolvedPlacement(
            proposedStart: timelineStart,
            duration: clip.sourceRange.duration,
            destinationTrackIndex: destinationIndex,
            requiredKind: requiredKind,
            snapAnchors: [currentTime]
        )
        return TimelinePlacementResult(
            start: placement.start,
            trackIndex: destinationIndex,
            snapped: placement.snapped
        )
    }

    @discardableResult
    func trimClipStart(
        _ clipID: UUID,
        by seconds: Double,
        baseline: TimelineClip? = nil,
        rebuild: Bool = true,
        interactive: Bool = false
    ) -> TimelineTrimResult? {
        if interactive {
            beginInteractiveEdit()
        }

        var result: TimelineTrimResult?
        mutateProject(
            rebuild: !interactive && rebuild,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive
        ) { project in
            guard let location = project.clipLocation(id: clipID) else { return }
            let currentClip = project.tracks[location.track].clips[location.clip]
            let reference = baseline ?? currentClip
            let previousEnd = project.neighborBounds(for: currentClip.id, in: location.track).previousEnd
            let maxForward = max(reference.sourceRange.duration - 0.1, 0)
            let maxBackward = -min(reference.sourceRange.start, reference.timelineStart - previousEnd)
            var applied = min(max(seconds, maxBackward), maxForward)
            let proposedEdge = reference.timelineStart + applied
            let snap = project.snappedTimelineEdge(
                proposedEdge,
                excluding: currentClip.id,
                requiredKind: currentClip.requiredTrackKind,
                snapAnchors: [currentTime]
            )
            if snap.snapped {
                applied = min(max(snap.time - reference.timelineStart, maxBackward), maxForward)
            }

            var clip = currentClip
            clip.timelineStart = reference.timelineStart + applied
            clip.sourceRange = TimeRangeValue(
                start: reference.sourceRange.start + applied,
                duration: reference.sourceRange.duration - applied
            )
            project.tracks[location.track].clips[location.clip] = clip
            project.tracks[location.track].clips.sort { $0.timelineStart < $1.timelineStart }
            selectedClipID = clip.id
            result = TimelineTrimResult(
                edgeTime: clip.timelineStart,
                appliedDelta: applied,
                snapped: snap.snapped && abs((reference.timelineStart + applied) - snap.time) < 0.001
            )
        }
        return result
    }

    func previewTrimClipStart(
        _ clipID: UUID,
        by seconds: Double,
        baseline: TimelineClip? = nil
    ) -> TimelineTrimResult? {
        guard let location = project.clipLocation(id: clipID) else { return nil }
        let currentClip = project.tracks[location.track].clips[location.clip]
        let reference = baseline ?? currentClip
        let previousEnd = project.neighborBounds(for: currentClip.id, in: location.track).previousEnd
        let maxForward = max(reference.sourceRange.duration - 0.1, 0)
        let maxBackward = -min(reference.sourceRange.start, reference.timelineStart - previousEnd)
        var applied = min(max(seconds, maxBackward), maxForward)
        let proposedEdge = reference.timelineStart + applied
        let snap = project.snappedTimelineEdge(
            proposedEdge,
            excluding: currentClip.id,
            requiredKind: currentClip.requiredTrackKind,
            snapAnchors: [currentTime]
        )
        if snap.snapped {
            applied = min(max(snap.time - reference.timelineStart, maxBackward), maxForward)
        }
        return TimelineTrimResult(
            edgeTime: reference.timelineStart + applied,
            appliedDelta: applied,
            snapped: snap.snapped && abs((reference.timelineStart + applied) - snap.time) < 0.001
        )
    }

    @discardableResult
    func trimClipEnd(
        _ clipID: UUID,
        by seconds: Double,
        baseline: TimelineClip? = nil,
        rebuild: Bool = true,
        interactive: Bool = false
    ) -> TimelineTrimResult? {
        if interactive {
            beginInteractiveEdit()
        }

        var result: TimelineTrimResult?
        mutateProject(
            rebuild: !interactive && rebuild,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive
        ) { project in
            guard let location = project.clipLocation(id: clipID) else { return }
            let currentClip = project.tracks[location.track].clips[location.clip]
            let reference = baseline ?? currentClip
            let nextStart = project.neighborBounds(for: currentClip.id, in: location.track).nextStart
            let sourceForwardLimit = reference.mediaType == .image
                ? Double.greatestFiniteMagnitude / 4
                : max(reference.source.originalDuration - reference.sourceRange.end, 0)
            let maxForward = min(sourceForwardLimit, max(nextStart - reference.timelineEnd, 0))
            let maxBackward = -max(reference.sourceRange.duration - 0.1, 0)
            var applied = min(max(seconds, maxBackward), maxForward)
            let proposedEdge = reference.timelineEnd + applied
            let snap = project.snappedTimelineEdge(
                proposedEdge,
                excluding: currentClip.id,
                requiredKind: currentClip.requiredTrackKind,
                snapAnchors: [currentTime]
            )
            if snap.snapped {
                applied = min(max(snap.time - reference.timelineEnd, maxBackward), maxForward)
            }

            var clip = currentClip
            clip.timelineStart = reference.timelineStart
            clip.sourceRange = TimeRangeValue(
                start: reference.sourceRange.start,
                duration: reference.sourceRange.duration + applied
            )
            project.tracks[location.track].clips[location.clip] = clip
            selectedClipID = clip.id
            result = TimelineTrimResult(
                edgeTime: clip.timelineEnd,
                appliedDelta: applied,
                snapped: snap.snapped && abs((reference.timelineEnd + applied) - snap.time) < 0.001
            )
        }
        return result
    }

    func previewTrimClipEnd(
        _ clipID: UUID,
        by seconds: Double,
        baseline: TimelineClip? = nil
    ) -> TimelineTrimResult? {
        guard let location = project.clipLocation(id: clipID) else { return nil }
        let currentClip = project.tracks[location.track].clips[location.clip]
        let reference = baseline ?? currentClip
        let nextStart = project.neighborBounds(for: currentClip.id, in: location.track).nextStart
        let sourceForwardLimit = reference.mediaType == .image
            ? Double.greatestFiniteMagnitude / 4
            : max(reference.source.originalDuration - reference.sourceRange.end, 0)
        let maxForward = min(sourceForwardLimit, max(nextStart - reference.timelineEnd, 0))
        let maxBackward = -max(reference.sourceRange.duration - 0.1, 0)
        var applied = min(max(seconds, maxBackward), maxForward)
        let proposedEdge = reference.timelineEnd + applied
        let snap = project.snappedTimelineEdge(
            proposedEdge,
            excluding: currentClip.id,
            requiredKind: currentClip.requiredTrackKind,
            snapAnchors: [currentTime]
        )
        if snap.snapped {
            applied = min(max(snap.time - reference.timelineEnd, maxBackward), maxForward)
        }
        return TimelineTrimResult(
            edgeTime: reference.timelineEnd + applied,
            appliedDelta: applied,
            snapped: snap.snapped && abs((reference.timelineEnd + applied) - snap.time) < 0.001
        )
    }

    func trimSelectedStart(by seconds: Double) {
        guard let selectedClipID else { return }
        mutateProject { project in
            guard let location = project.clipLocation(id: selectedClipID) else { return }
            var clip = project.tracks[location.track].clips[location.clip]
            let maxForward = max(clip.sourceRange.duration - 0.1, 0)
            let previousEnd = project.neighborBounds(for: clip.id, in: location.track).previousEnd
            let maxBackward = -min(clip.sourceRange.start, clip.timelineStart - previousEnd)
            let applied = min(max(seconds, maxBackward), maxForward)
            clip.timelineStart += applied
            clip.sourceRange = TimeRangeValue(
                start: clip.sourceRange.start + applied,
                duration: clip.sourceRange.duration - applied
            )
            project.tracks[location.track].clips[location.clip] = clip
        }
    }

    func trimSelectedEnd(by seconds: Double) {
        guard let selectedClipID else { return }
        mutateProject { project in
            guard let location = project.clipLocation(id: selectedClipID) else { return }
            var clip = project.tracks[location.track].clips[location.clip]
            let nextStart = project.neighborBounds(for: clip.id, in: location.track).nextStart
            let sourceForwardLimit = clip.mediaType == .image
                ? Double.greatestFiniteMagnitude / 4
                : max(clip.source.originalDuration - clip.sourceRange.end, 0)
            let maxForward = min(sourceForwardLimit, max(nextStart - clip.timelineEnd, 0))
            let maxBackward = -max(clip.sourceRange.duration - 0.1, 0)
            let applied = min(max(seconds, maxBackward), maxForward)
            clip.sourceRange = TimeRangeValue(
                start: clip.sourceRange.start,
                duration: clip.sourceRange.duration + applied
            )
            project.tracks[location.track].clips[location.clip] = clip
        }
    }

    func setSelectedClipTimelineStart(_ time: Double) {
        guard let selectedClipID else { return }
        mutateProject { project in
            guard let location = project.clipLocation(id: selectedClipID) else { return }
            let clip = project.tracks[location.track].clips.remove(at: location.clip)
            var movedClip = clip
            movedClip.timelineStart = project.resolvedPlacementStart(
                proposedStart: time,
                duration: clip.sourceRange.duration,
                destinationTrackIndex: location.track,
                requiredKind: clip.requiredTrackKind
            )
            project.tracks[location.track].clips.append(movedClip)
            project.tracks[location.track].clips.sort { $0.timelineStart < $1.timelineStart }
        }
    }

    func deselectTimeline() {
        updateSelection(clipID: nil, trackID: nil)
    }

    func setCanvasPreset(_ preset: CanvasRatioPreset) {
        mutateProject {
            $0.renderSettings = preset.settings(frameRate: $0.renderSettings.frameRate)
        }
    }

    var canApplySelectedClipOriginalRatio: Bool {
        guard let clip = selectedClip, clip.mediaType != .audio else { return false }
        return clip.source.naturalSize != nil
    }

    func setCanvasToSelectedClipOriginalRatio() {
        guard let clip = selectedClip,
              clip.mediaType != .audio,
              let naturalSize = clip.source.naturalSize?.displaySafeSize
        else { return }

        mutateProject {
            $0.renderSettings = RenderSettings(size: naturalSize, frameRate: $0.renderSettings.frameRate)
        }
    }

    func updateSelectedClip(
        rebuild: Bool = true,
        recordHistory: Bool = true,
        persistChanges: Bool = true,
        touchUpdatedAt: Bool = true,
        refreshTimeline: Bool = true,
        _ update: (inout TimelineClip) -> Void
    ) {
        guard let selectedClipID else { return }
        mutateProject(
            rebuild: rebuild,
            recordHistory: recordHistory,
            persistChanges: persistChanges,
            touchUpdatedAt: touchUpdatedAt,
            refreshTimeline: refreshTimeline
        ) { project in
            guard let location = project.clipLocation(id: selectedClipID) else { return }
            update(&project.tracks[location.track].clips[location.clip])
        }
    }

    func setSelectedTransform(
        positionX: Double? = nil,
        positionY: Double? = nil,
        scale: Double? = nil,
        rotationDegrees: Double? = nil,
        opacity: Double? = nil,
        interactive: Bool = false
    ) {
        if interactive {
            beginInteractiveEdit()
        }

        updateSelectedClip(
            rebuild: !interactive,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive,
            refreshTimeline: false
        ) { clip in
            if let positionX {
                clip.transform.positionX.baseValue = min(max(positionX, -2), 2)
            }
            if let positionY {
                clip.transform.positionY.baseValue = min(max(positionY, -2), 2)
            }
            if let scale {
                clip.transform.scale.baseValue = min(max(scale, 0.05), 8)
            }
            if let rotationDegrees {
                clip.transform.rotationDegrees.baseValue = rotationDegrees
            }
            if let opacity {
                clip.transform.opacity.baseValue = min(max(opacity, 0), 1)
            }
        }
    }

    func beginInteractiveEdit() {
        if interactiveEditSnapshot == nil {
            interactiveEditSnapshot = project
        }
    }

    func finishInteractiveEdit(rebuild: Bool = true) {
        guard let snapshot = interactiveEditSnapshot else {
            persist()
            if rebuild {
                schedulePreviewRebuild(seekTo: currentTime)
            }
            return
        }

        interactiveEditSnapshot = nil
        guard project != snapshot else { return }

        undoStack.append(snapshot)
        if undoStack.count > 80 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        updateHistoryFlags()
        project.updatedAt = Date()
        persist()
        if rebuild {
            schedulePreviewRebuild(seekTo: currentTime)
        }
    }

    func setEffect(_ kind: ClipEffectKind?) {
        updateSelectedClip { clip in
            if let kind {
                if clip.effectStack.effects.isEmpty {
                    clip.effectStack.effects = [ClipEffect(kind: kind)]
                } else {
                    clip.effectStack.effects[0].kind = kind
                    clip.effectStack.effects[0].isEnabled = true
                }
            } else {
                clip.effectStack.effects.removeAll()
            }
        }
    }

    func setEffectIntensity(_ value: Double) {
        updateSelectedClip { clip in
            guard !clip.effectStack.effects.isEmpty else { return }
            clip.effectStack.effects[0].intensity.baseValue = min(max(value, 0), 1)
        }
    }

    func addKeyframe(_ target: KeyframeTarget) {
        guard let selectedClipID else { return }
        mutateProject { project in
            guard let location = project.clipLocation(id: selectedClipID) else { return }
            var clip = project.tracks[location.track].clips[location.clip]
            let time = max(0, currentTime - clip.timelineStart)

            switch target {
            case .positionX:
                clip.transform.positionX.insertKeyframe(at: time)
            case .positionY:
                clip.transform.positionY.insertKeyframe(at: time)
            case .scale:
                clip.transform.scale.insertKeyframe(at: time)
            case .rotation:
                clip.transform.rotationDegrees.insertKeyframe(at: time)
            case .opacity:
                clip.transform.opacity.insertKeyframe(at: time)
            case .brightness:
                clip.adjustments.brightness.insertKeyframe(at: time)
            case .contrast:
                clip.adjustments.contrast.insertKeyframe(at: time)
            case .saturation:
                clip.adjustments.saturation.insertKeyframe(at: time)
            case .exposure:
                clip.adjustments.exposure.insertKeyframe(at: time)
            case .effect(let effectID):
                if let effectIndex = clip.effectStack.effects.firstIndex(where: { $0.id == effectID }) {
                    clip.effectStack.effects[effectIndex].intensity.insertKeyframe(at: time)
                }
            }

            project.tracks[location.track].clips[location.clip] = clip
        }
    }

    func exportProject() {
        Task {
            guard !isExporting else { return }
            isExporting = true
            exportProgress = 0
            do {
                let url = try await exportService.export(project: project) { [weak self] progress in
                    Task { @MainActor in
                        self?.exportProgress = progress
                    }
                }
                shareURL = url
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }

    func extractAudioFromSelectedClip() {
        guard let selectedClipID,
              let clip = selectedClip,
              clip.mediaType == .video
        else { return }

        Task {
            do {
                let asset = AVURLAsset(url: clip.source.url)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                guard !audioTracks.isEmpty else {
                    errorMessage = "This video does not contain an audio track."
                    return
                }

                mutateProject { project in
                    guard let location = project.clipLocation(id: selectedClipID) else { return }
                    let videoClip = project.tracks[location.track].clips[location.clip]
                    project.tracks[location.track].clips[location.clip].volume = 0

                    let audioSource = ClipSource(
                        url: videoClip.source.url,
                        mediaType: .audio,
                        originalDuration: videoClip.source.originalDuration,
                        naturalSize: nil
                    )
                    let audioClip = TimelineClip(
                        name: "\(videoClip.name) Audio",
                        source: audioSource,
                        timelineStart: videoClip.timelineStart,
                        sourceRange: videoClip.sourceRange,
                        volume: max(videoClip.volume, 1)
                    )
                    let audioTrackIndex = project.insertFreshTrack(kind: .audio)
                    project.tracks[audioTrackIndex].clips.append(audioClip)
                    project.tracks[audioTrackIndex].clips.sort { $0.timelineStart < $1.timelineStart }
                    self.selectedTrackID = project.tracks[audioTrackIndex].id
                    self.selectedClipID = audioClip.id
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func rebuildPreview(seekTo time: Double? = nil) async {
        let seekTime = min(max(time ?? currentTime, 0), max(duration, 0))
        let shouldResume = isPlaying
        isRenderingPreview = true
        defer {
            if !Task.isCancelled {
                isRenderingPreview = false
            }
        }
        do {
            let item = try await renderService.makePlayerItem(for: project)
            guard !Task.isCancelled else { return }
            if let item {
                if player == nil {
                    player = AVPlayer(playerItem: item)
                    player?.volume = 1
                } else {
                    player?.replaceCurrentItem(with: item)
                }
                installTimeObserver()
                seek(to: seekTime)
                if shouldResume {
                    player?.play()
                    isPlaying = true
                }
            } else {
                player?.pause()
                player = nil
                updateCurrentTime(0)
                isPlaying = false
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func addImportedMedia(_ imported: ImportedMedia, sequentialVisual: Bool = false) {
        mutateProject { project in
            let kind: TrackKind = imported.source.mediaType == .audio ? .audio : .visual
            let hadVisualClips = project.tracks.contains { $0.kind == .visual && !$0.clips.isEmpty }
            let trackIndex = project.insertFreshTrack(kind: kind)
            let targetInsertionTime: Double
            if kind == .visual, hadVisualClips, !sequentialVisual {
                targetInsertionTime = currentTime
            } else {
                targetInsertionTime = insertionTime(for: kind, in: project)
            }
            let clip = TimelineClip(
                name: imported.storedURL.deletingPathExtension().lastPathComponent,
                source: imported.source,
                timelineStart: targetInsertionTime,
                sourceRange: TimeRangeValue(start: 0, duration: imported.source.originalDuration)
            )
            project.tracks[trackIndex].clips.append(clip)
            project.tracks[trackIndex].clips.sort { $0.timelineStart < $1.timelineStart }
            if kind == .visual, !hadVisualClips, let naturalSize = imported.source.naturalSize?.displaySafeSize {
                project.renderSettings = RenderSettings(size: naturalSize)
            }
            project.removeEmptyAutoTracks()
            project.renumberTracks()
            selectedTrackID = project.tracks[trackIndex].id
            selectedClipID = clip.id
            selectedTool = .edit
        }
    }

    private func repairStoredMediaReferences() {
        var repaired = project
        var changed = false

        for trackIndex in repaired.tracks.indices {
            for clipIndex in repaired.tracks[trackIndex].clips.indices {
                let url = repaired.tracks[trackIndex].clips[clipIndex].source.url
                let resolved = projectStore.resolvedMediaURL(url, projectID: projectID)
                if resolved != url {
                    repaired.tracks[trackIndex].clips[clipIndex].source.url = resolved
                    changed = true
                }
            }
        }

        if changed {
            project = repaired
            incrementTimelineContentRevision()
            persist()
        }
    }

    private func insertionTime(for kind: TrackKind, in project: EditorProject) -> Double {
        switch kind {
        case .visual:
            let visualDuration = project.tracks
                .filter { $0.kind == .visual }
                .flatMap(\.clips)
                .map(\.timelineEnd)
                .max() ?? 0
            return visualDuration
        case .audio:
            return min(currentTime, max(project.duration, currentTime))
        }
    }

    private func activeVisualClipID(at time: Double) -> UUID? {
        project.tracks
            .filter { $0.kind == .visual }
            .flatMap(\.clips)
            .filter { time >= $0.timelineStart && time < $0.timelineEnd }
            .last?
            .id
    }

    private func mutateProject(
        rebuild: Bool = true,
        recordHistory: Bool = true,
        persistChanges: Bool = true,
        touchUpdatedAt: Bool = true,
        refreshTimeline: Bool = true,
        _ mutation: (inout EditorProject) -> Void
    ) {
        let previous = project
        mutation(&project)
        project.removeEmptyAutoTracks()
        project.renumberTracks()
        guard project != previous else { return }
        if refreshTimeline {
            incrementTimelineContentRevision()
        }
        if recordHistory {
            undoStack.append(previous)
            if undoStack.count > 80 {
                undoStack.removeFirst()
            }
            redoStack.removeAll()
            updateHistoryFlags()
        }
        if touchUpdatedAt {
            project.updatedAt = Date()
        }
        if persistChanges {
            persist()
        }
        if rebuild {
            schedulePreviewRebuild(seekTo: currentTime)
        }
    }

    private func schedulePreviewRebuild(seekTo time: Double? = nil, delay: Bool = true) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            if delay {
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
            guard !Task.isCancelled else { return }
            await self.rebuildPreview(seekTo: time)
        }
    }

    private func persist() {
        projectStore.saveContent(ProjectContent(editorProject: project), for: projectID)
    }

    private func installTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }

        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                let seconds = CMTimeGetSeconds(time)
                if !self.isScrubbing {
                    self.updateCurrentTime(min(max(seconds, 0), max(self.duration, 0)))
                }
                if self.duration > 0, seconds >= self.duration - 0.04 {
                    self.player?.pause()
                    self.isPlaying = false
                }
            }
        }
    }

    private func setBusyImporting(_ value: Bool) async {
        isImporting = value
    }

    private func updateHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func updateCurrentTime(_ time: Double) {
        currentTime = time
        validateSelectedClipVisibility()
    }

    private func updateSelection(clipID: UUID?, trackID: UUID?) {
        let changed = selectedClipID != clipID || selectedTrackID != trackID
        selectedClipID = clipID
        selectedTrackID = trackID
        if changed {
            incrementTimelineContentRevision()
        }
    }

    private func validateSelectedClipVisibility() {
        guard let selectedClipID else { return }
        guard let clip = project.clip(id: selectedClipID), isTimeInside(clip) else {
            updateSelection(clipID: nil, trackID: selectedTrackID)
            return
        }
    }

    private func isTimeInside(_ clip: TimelineClip) -> Bool {
        currentTime >= clip.timelineStart && currentTime < clip.timelineEnd
    }

    private func nearestVisibleTime(for clip: TimelineClip) -> Double {
        let epsilon = min(max(clip.sourceRange.duration * 0.05, 0.001), clipRevealEpsilon)
        if currentTime < clip.timelineStart {
            return min(clip.timelineStart + epsilon, max(clip.timelineStart, clip.timelineEnd - epsilon))
        }
        return max(clip.timelineStart, clip.timelineEnd - epsilon)
    }

    private func incrementTimelineContentRevision() {
        timelineContentRevision &+= 1
    }
}

private extension EditorProject {
    func clip(id: UUID) -> TimelineClip? {
        tracks.flatMap(\.clips).first { $0.id == id }
    }

    func clipLocation(id: UUID) -> (track: Int, clip: Int)? {
        for trackIndex in tracks.indices {
            if let clipIndex = tracks[trackIndex].clips.firstIndex(where: { $0.id == id }) {
                return (trackIndex, clipIndex)
            }
        }
        return nil
    }

    mutating func ensureTrack(kind: TrackKind) -> Int {
        if let selectedIndex = tracks.firstIndex(where: { $0.id == selectedTrackIDCandidate(kind: kind) && $0.kind == kind }) {
            return selectedIndex
        }
        if let existingIndex = tracks.firstIndex(where: { $0.kind == kind }) {
            return existingIndex
        }

        let name = kind == .visual ? "Layer 1" : "Audio 1"
        tracks.append(TimelineTrack(name: name, kind: kind))
        return tracks.count - 1
    }

    mutating func insertFreshTrack(kind: TrackKind) -> Int {
        let hasClipsInKind = tracks.contains { $0.kind == kind && !$0.clips.isEmpty }
        if !hasClipsInKind, let emptyIndex = tracks.firstIndex(where: { $0.kind == kind && $0.clips.isEmpty }) {
            return emptyIndex
        }

        switch kind {
        case .visual:
            let insertionIndex = tracks.firstIndex(where: { $0.kind == .visual }) ?? 0
            tracks.insert(TimelineTrack(name: nextTrackName(for: kind), kind: kind), at: insertionIndex)
            return insertionIndex
        case .audio:
            tracks.append(TimelineTrack(name: nextTrackName(for: kind), kind: kind))
            return tracks.count - 1
        }
    }

    mutating func compatibleTrackIndex(proposedIndex: Int, requiredKind: TrackKind) -> Int {
        if tracks.indices.contains(proposedIndex), tracks[proposedIndex].kind == requiredKind {
            return proposedIndex
        }

        let matching = tracks.indices.filter { tracks[$0].kind == requiredKind }
        if proposedIndex < (matching.first ?? Int.max) {
            tracks.insert(TimelineTrack(name: nextTrackName(for: requiredKind), kind: requiredKind), at: matching.first ?? 0)
            return matching.first ?? 0
        }

        if proposedIndex > (matching.last ?? -1) {
            let insertionIndex = requiredKind == .visual
                ? (matching.last.map { $0 + 1 } ?? 0)
                : tracks.count
            tracks.insert(TimelineTrack(name: nextTrackName(for: requiredKind), kind: requiredKind), at: insertionIndex)
            return insertionIndex
        }

        if let nearest = matching.min(by: { abs($0 - proposedIndex) < abs($1 - proposedIndex) }) {
            return nearest
        }

        tracks.append(TimelineTrack(name: nextTrackName(for: requiredKind), kind: requiredKind))
        return tracks.count - 1
    }

    mutating func insertCompatibleTrack(at proposedIndex: Int, requiredKind: TrackKind) -> Int {
        let clampedIndex = min(max(proposedIndex, 0), tracks.count)
        tracks.insert(TimelineTrack(name: nextTrackName(for: requiredKind), kind: requiredKind), at: clampedIndex)
        return clampedIndex
    }

    mutating func removeEmptyAutoTracks() {
        let hasAnyClips = tracks.contains { !$0.clips.isEmpty }
        var keptEmptyVisual = false

        tracks.removeAll { track in
            guard track.clips.isEmpty else { return false }
            guard hasAnyClips else {
                if track.kind == .visual, !keptEmptyVisual {
                    keptEmptyVisual = true
                    return false
                }
                return true
            }
            return true
        }

        if tracks.allSatisfy({ $0.kind != .visual }) {
            tracks.insert(TimelineTrack(name: "Layer 1", kind: .visual), at: 0)
        }
    }

    mutating func renumberTracks() {
        var visualIndex = 1
        var audioIndex = 1
        for index in tracks.indices {
            switch tracks[index].kind {
            case .visual:
                tracks[index].name = "Layer \(visualIndex)"
                visualIndex += 1
            case .audio:
                tracks[index].name = "Audio \(audioIndex)"
                audioIndex += 1
            }
        }
    }

    private func nextTrackName(for kind: TrackKind) -> String {
        let count = tracks.filter { $0.kind == kind }.count + 1
        return kind == .visual ? "Layer \(count)" : "Audio \(count)"
    }

    private func selectedTrackIDCandidate(kind: TrackKind) -> UUID? {
        tracks.first(where: { $0.kind == kind })?.id
    }

    func resolvedPlacementStart(
        proposedStart: Double,
        duration: Double,
        destinationTrackIndex: Int,
        requiredKind: TrackKind,
        snapThreshold: Double = 0.16,
        snapAnchors: [Double] = []
    ) -> Double {
        resolvedPlacement(
            proposedStart: proposedStart,
            duration: duration,
            destinationTrackIndex: destinationTrackIndex,
            requiredKind: requiredKind,
            snapThreshold: snapThreshold,
            snapAnchors: snapAnchors
        ).start
    }

    func resolvedPlacement(
        proposedStart: Double,
        duration: Double,
        destinationTrackIndex: Int,
        requiredKind: TrackKind,
        snapThreshold: Double = 0.16,
        snapAnchors: [Double] = []
    ) -> (start: Double, snapped: Bool) {
        let safeDuration = max(duration, 0.001)
        let baseStart = max(0, proposedStart)
        let baseEnd = baseStart + safeDuration
        var candidate = baseStart
        var snapped = false

        let compatibleClips = tracks
            .filter { $0.kind == requiredKind }
            .flatMap(\.clips)

        var bestDistance = snapThreshold
        let anchors = (snapAnchors + compatibleClips.flatMap { [$0.timelineStart, $0.timelineEnd] })
            .filter { $0.isFinite }

        for anchor in anchors {
            let startDistance = abs(baseStart - anchor)
            if startDistance < bestDistance {
                bestDistance = startDistance
                candidate = max(0, anchor)
                snapped = true
            }

            let endDistance = abs(baseEnd - anchor)
            if endDistance < bestDistance {
                bestDistance = endDistance
                candidate = max(0, anchor - safeDuration)
                snapped = true
            }
        }

        guard tracks.indices.contains(destinationTrackIndex) else {
            return (candidate, snapped)
        }

        let clipsInDestination = tracks[destinationTrackIndex].clips
            .sorted { $0.timelineStart < $1.timelineStart }
        let nonOverlappingStart = nearestNonOverlappingStart(
            proposedStart: candidate,
            duration: safeDuration,
            clips: clipsInDestination
        )
        return (nonOverlappingStart, snapped || abs(nonOverlappingStart - candidate) > 0.001)
    }

    func snappedTimelineEdge(
        _ proposedEdge: Double,
        excluding clipID: UUID,
        requiredKind: TrackKind,
        snapThreshold: Double = 0.16,
        snapAnchors: [Double] = []
    ) -> (time: Double, snapped: Bool) {
        let boundedEdge = max(0, proposedEdge)
        let otherClips = tracks
            .filter { $0.kind == requiredKind }
            .flatMap(\.clips)
            .filter { $0.id != clipID }
        let otherDuration = otherClips.map(\.timelineEnd).max() ?? 0
        let anchors = ([0, otherDuration] + snapAnchors + otherClips.flatMap { [$0.timelineStart, $0.timelineEnd] })
            .filter { $0.isFinite }

        guard let best = anchors.min(by: { abs($0 - boundedEdge) < abs($1 - boundedEdge) }),
              abs(best - boundedEdge) < snapThreshold
        else {
            return (boundedEdge, false)
        }

        return (max(0, best), true)
    }

    private func nearestNonOverlappingStart(proposedStart: Double, duration: Double, clips: [TimelineClip]) -> Double {
        guard !clips.isEmpty else { return max(0, proposedStart) }

        var ranges: [(start: Double, end: Double)] = []
        var cursor = 0.0

        for clip in clips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
            if clip.timelineStart - cursor >= duration {
                ranges.append((cursor, clip.timelineStart - duration))
            }
            cursor = max(cursor, clip.timelineEnd)
        }
        ranges.append((cursor, Double.greatestFiniteMagnitude / 4))

        let boundedStart = max(0, proposedStart)
        let best = ranges
            .map { range -> Double in
                min(max(boundedStart, range.start), range.end)
            }
            .min { abs($0 - boundedStart) < abs($1 - boundedStart) }

        return max(0, best ?? boundedStart)
    }

    func neighborBounds(for clipID: UUID, in trackIndex: Int) -> (previousEnd: Double, nextStart: Double) {
        guard tracks.indices.contains(trackIndex),
              let clip = tracks[trackIndex].clips.first(where: { $0.id == clipID })
        else {
            return (0, Double.greatestFiniteMagnitude / 4)
        }

        let clips = tracks[trackIndex].clips.filter { $0.id != clipID }
        let previousEnd = clips
            .filter { $0.timelineEnd <= clip.timelineStart + 0.001 }
            .map(\.timelineEnd)
            .max() ?? 0
        let nextStart = clips
            .filter { $0.timelineStart >= clip.timelineEnd - 0.001 }
            .map(\.timelineStart)
            .min() ?? Double.greatestFiniteMagnitude / 4

        return (previousEnd, nextStart)
    }
}

private extension CGSizeValue {
    var displaySafeSize: CGSize {
        CGSize(width: max(abs(width), 1), height: max(abs(height), 1))
    }
}

private extension TimelineClip {
    var requiredTrackKind: TrackKind {
        mediaType == .audio ? .audio : .visual
    }
}

private extension AnimatableProperty where Value == Double {
    mutating func insertKeyframe(at time: Double) {
        let frame = Keyframe(time: time, value: baseValue)
        if let index = keyframes.firstIndex(where: { abs($0.time - time) < 0.04 }) {
            keyframes[index] = frame
        } else {
            keyframes.append(frame)
        }
        keyframes.sort { $0.time < $1.time }
    }
}
