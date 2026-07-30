// Imported-media insertion, persistence, mutation history, and selection validation.

import AVFoundation
import Foundation
import os

private let previewRenderMetricsLog = OSLog(
    subsystem: "com.moysoft.motionary",
    category: .pointsOfInterest
)

extension EditorViewModel {
    func addImportedMedia(_ imported: ImportedMedia, sequentialVisual: Bool = false) {
        let before = project
        var after = project
        let kind: TrackKind = imported.source.mediaType == .audio ? .audio : .visual
        let hadVisualClips = after.tracks.contains { $0.kind == .visual && !$0.clips.isEmpty }
        let targetInsertionTime: Double
        if kind == .visual, hadVisualClips, !sequentialVisual {
            targetInsertionTime = visibleInsertionTime(at: currentTime)
        } else {
            targetInsertionTime = insertionTime(for: kind, in: after)
        }
        let trackIndex =
            after.topAvailableTrackIndex(
                kind: kind,
                start: targetInsertionTime,
                duration: imported.source.originalDuration
            )
            ?? after.insertFreshTrack(kind: kind)
        var clip = TimelineClip(
            name: imported.storedURL.deletingPathExtension().lastPathComponent,
            source: imported.source,
            timelineStart: targetInsertionTime,
            sourceRange: TimeRangeValue(start: 0, duration: imported.source.originalDuration)
        )
        after.registerClipMedia(&clip, source: imported.source)
        after.tracks[trackIndex].appendLegacyClip(clip)
        if kind == .visual, !hadVisualClips, let naturalSize = imported.source.naturalSize?.displaySafeSize {
            after.renderSettings = RenderSettings(size: naturalSize)
        }
        after.renumberTracks()
        after.synchronizeMediaLibrary()
        selectedTrackID = after.tracks[trackIndex].id
        selectedClipID = clip.id
        commit(
            EditorCommandFactory.importMedia(
                before: before,
                after: after,
                invalidation: [.previewFrame, .compositionTopology, .audioMix, .timelineLayout, .userInterface, .persistence]
            ),
            seekTo: targetInsertionTime
        )
    }

    func repairStoredMediaReferences() {
        var repaired = project
        var changed = false

        for (mediaID, asset) in repaired.mediaLibrary {
            let resolved = projectStore.resolvedMediaURL(asset.url, projectID: projectID)
            if resolved != asset.url {
                var source = asset.source
                source.url = resolved
                repaired.updateMediaAsset(mediaID, source: source)
                changed = true
            }
        }

        if changed {
            let before = project
            commit(
                EditorCommandFactory.importMedia(
                    before: before,
                    after: repaired,
                    invalidation: [.previewFrame, .compositionTopology, .audioMix, .persistence]
                ),
                refreshTimeline: true
            )
        }
    }

    func insertionTime(for kind: TrackKind, in project: EditorProject) -> Double {
        switch kind {
        case .undefined:
            return 0
        case .visual:
            let visualDuration =
                project.tracks
                .filter { $0.kind == .visual }
                .flatMap(\.clips)
                .map(\.timelineEnd)
                .max() ?? 0
            return visualDuration
        case .shape, .text:
            return visibleInsertionTime(at: currentTime)
        case .audio:
            return min(currentTime, max(project.duration, currentTime))
        }
    }

    func visibleInsertionTime(at time: Double) -> Double {
        let frameRate = Double(max(project.renderSettings.frameRate, 1))
        let frameTime = floor(max(time, 0) * frameRate) / frameRate
        return min(frameTime, max(project.duration, frameTime))
    }

    func commit(
        _ command: AnyEditorCommand,
        recordHistory: Bool = true,
        persistChanges: Bool = true,
        touchUpdatedAt: Bool = true,
        refreshTimeline: Bool = true,
        seekTo time: Double? = nil
    ) {
        perform(
            command,
            recordHistory: recordHistory,
            persistChanges: persistChanges,
            touchUpdatedAt: touchUpdatedAt,
            refreshTimeline: refreshTimeline
        )
        if let time {
            updateCurrentTime(clampedTimelineTime(time))
        }
    }

    func mutateProject(
        rebuild: Bool = true,
        recordHistory: Bool = true,
        persistChanges: Bool = true,
        touchUpdatedAt: Bool = true,
        refreshTimeline: Bool = true,
        _ mutation: (inout EditorProject) -> Void
    ) {
        if !rebuild, !recordHistory, !persistChanges, !touchUpdatedAt {
            mutation(&project)
            project.renumberTracks()
            project.synchronizeMediaLibrary()
            if refreshTimeline {
                incrementTimelineContentRevision()
            }
            return
        }

        let before = project
        var after = project
        mutation(&after)
        after.renumberTracks()
        after.synchronizeMediaLibrary()
        guard after != before else { return }

        var renderInvalidation = after.renderInvalidation(comparedTo: before)
        if !rebuild {
            renderInvalidation.subtract([.previewFrame, .compositionTopology, .audioMix])
        }
        var invalidation: EditorInvalidation = [.userInterface, .persistence]
        invalidation.formUnion(renderInvalidation)
        if refreshTimeline {
            invalidation.insert(.timelineLayout)
        }

        perform(
            after.historyCommand(from: before, invalidation: invalidation),
            recordHistory: recordHistory,
            persistChanges: persistChanges,
            touchUpdatedAt: touchUpdatedAt,
            refreshTimeline: refreshTimeline
        )
    }

    func perform(
        _ command: AnyEditorCommand,
        recordHistory: Bool = true,
        persistChanges: Bool = true,
        touchUpdatedAt: Bool = true,
        refreshTimeline: Bool = true
    ) {
        command.apply(to: &project)
        if command.invalidation.contains(.persistence) || command.invalidation.contains(.compositionTopology) {
            project.synchronizeMediaLibrary()
        }
        project.renumberTracks()
        updateCurrentTime(clampedTimelineTime(currentTime))
        if refreshTimeline {
            incrementTimelineContentRevision()
            timelineClipCacheRevision = -1
            timelineSnapshotToken = (-1, nil)
        }
        if recordHistory {
            undoStack.append(command)
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
        if !command.invalidation.intersection([.previewFrame, .compositionTopology, .audioMix]).isEmpty {
            schedulePreviewRebuild(seekTo: currentTime, invalidation: command.invalidation)
        }
    }

    func schedulePreviewRebuild(
        seekTo time: Double? = nil,
        delay: Bool = true,
        invalidation: EditorInvalidation = [.previewFrame]
    ) {
        if isScrubbing {
            deferredPreviewInvalidation.formUnion(invalidation)
            return
        }

        if rebuildTask != nil, invalidation.contains(.previewFrame) {
            os_signpost(.event, log: previewRenderMetricsLog, name: "Dropped Preview Frame")
        }
        rebuildTask?.cancel()
        previewGeneration &+= 1
        let generation = previewGeneration
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.previewGeneration {
                    self.rebuildTask = nil
                }
            }
            if delay {
                try? await Task.sleep(nanoseconds: 160_000_000)
            }
            guard !Task.isCancelled, !self.isScrubbing else { return }
            await self.rebuildPreview(
                seekTo: time,
                invalidation: invalidation,
                generation: generation
            )
        }
    }

    func scheduleInteractivePreviewRebuild(
        invalidation: EditorInvalidation
    ) {
        setPreviewQualityForInteraction(true)
        pendingInteractivePreviewInvalidation.formUnion(invalidation)
        // Coalesce mutations to a 60 Hz presentation cadence. The compositor's
        // in-flight gate supplies the additional backpressure when a frame is
        // more expensive than one display tick.
        let interval = 1.0 / 60.0
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastInteractivePreviewRebuild

        if elapsed >= interval, !isRenderingPreview {
            interactivePreviewThrottleTask?.cancel()
            interactivePreviewThrottleTask = nil
            let rebuildInvalidation = pendingInteractivePreviewInvalidation
            pendingInteractivePreviewInvalidation = []
            guard !rebuildInvalidation.isEmpty else { return }
            lastInteractivePreviewRebuild = now
            schedulePreviewRebuild(
                seekTo: currentTime,
                delay: false,
                invalidation: rebuildInvalidation
            )
            return
        }

        guard interactivePreviewThrottleTask == nil else { return }
        let remaining = isRenderingPreview ? interval : max(interval - elapsed, 0)
        interactivePreviewThrottleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else { return }
            self.interactivePreviewThrottleTask = nil
            guard !self.pendingInteractivePreviewInvalidation.isEmpty else { return }
            self.scheduleInteractivePreviewRebuild(invalidation: [])
        }
    }

    func cancelInteractivePreviewRebuild(cancelLivePreviewRefresh: Bool = true) {
        interactivePreviewThrottleTask?.cancel()
        interactivePreviewThrottleTask = nil
        pendingInteractivePreviewInvalidation = []
        lastInteractivePreviewRebuild = 0
        if cancelLivePreviewRefresh {
            livePreviewFrameRefreshTask?.cancel()
            livePreviewFrameRefreshTask = nil
            pendingLivePreviewFrameRefresh = false
            livePreviewFrameRefreshInFlight = false
            lastLivePreviewFrameRefresh = 0
        }
    }

    func beginLivePreviewInteraction() {
        livePreviewInteractionGeneration &+= 1
        livePreviewOverrideClearTask?.cancel()
        livePreviewOverrideClearTask = nil
        cancelInteractivePreviewRebuild()
        rebuildTask?.cancel()
        rebuildTask = nil
        previewGeneration &+= 1
        isRenderingPreview = false
        setPreviewQualityForInteraction(true)
    }

    func updateLivePreviewTransform(
        _ transform: ClipTransform,
        for itemID: UUID,
        hidden: Bool? = nil,
        immediate: Bool = false
    ) {
        if let hidden {
            renderService.livePreviewState.setTransform(transform, hidden: hidden, for: itemID)
        } else {
            renderService.livePreviewState.setTransform(transform, for: itemID)
        }
        if immediate {
            livePreviewFrameRefreshTask?.cancel()
            livePreviewFrameRefreshTask = nil
            pendingLivePreviewFrameRefresh = true
            issueLivePreviewFrameRefresh()
        } else {
            scheduleLivePreviewFrameRefresh()
        }
    }

    func hideLivePreviewSource(for itemID: UUID) {
        renderService.livePreviewState.setHidden(true, for: itemID)
        scheduleLivePreviewFrameRefresh()
    }

    func showLivePreviewSource(for itemID: UUID?, refresh: Bool = true) {
        if let itemID {
            renderService.livePreviewState.clearTransform(for: itemID)
        } else {
            renderService.livePreviewState.removeAll()
        }
        if refresh {
            scheduleLivePreviewFrameRefresh()
        }
    }

    func showLivePreviewSourcePreservingTransform(for itemID: UUID, refresh: Bool = true) {
        renderService.livePreviewState.revealPreservingTransform(for: itemID)
        if refresh {
            scheduleLivePreviewFrameRefresh()
        }
    }

    func finishLivePreviewCommitPresentation(for itemID: UUID?) {
        livePreviewInteractionGeneration &+= 1
        let generation = livePreviewInteractionGeneration
        livePreviewOverrideClearTask?.cancel()
        previewQuality = .balanced
        schedulePreviewRebuild(
            seekTo: currentTime,
            delay: true,
            invalidation: [.previewFrame]
        )
        guard let itemID else { return }
        livePreviewOverrideClearTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.livePreviewOverrideClearTask = nil
            guard self.livePreviewInteractionGeneration == generation,
                !self.isScrubbing,
                !self.isPlaying
            else { return }
            self.showLivePreviewSource(for: itemID, refresh: false)
        }
    }

    func clearLivePreviewTransform(for itemID: UUID?, refresh: Bool = true) {
        if let itemID {
            renderService.livePreviewState.clearTransform(for: itemID)
        } else {
            renderService.livePreviewState.removeAll()
        }
        if refresh {
            scheduleLivePreviewFrameRefresh()
        }
    }

    private func scheduleLivePreviewFrameRefresh() {
        setPreviewQualityForInteraction(true)
        guard !isScrubbing else { return }
        pendingLivePreviewFrameRefresh = true

        let interval = livePreviewRefreshInterval()
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastLivePreviewFrameRefresh

        if elapsed >= interval, !isRenderingPreview, !livePreviewFrameRefreshInFlight {
            livePreviewFrameRefreshTask?.cancel()
            livePreviewFrameRefreshTask = nil
            issueLivePreviewFrameRefresh()
            return
        }

        guard livePreviewFrameRefreshTask == nil else { return }
        let remaining =
            (isRenderingPreview || livePreviewFrameRefreshInFlight)
            ? interval
            : max(interval - elapsed, 0)
        livePreviewFrameRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else { return }
            self.livePreviewFrameRefreshTask = nil
            self.issueLivePreviewFrameRefresh()
        }
    }

    private func issueLivePreviewFrameRefresh() {
        guard pendingLivePreviewFrameRefresh else { return }
        guard let player else { return }
        guard !isPlaying else { return }
        guard !livePreviewFrameRefreshInFlight, !isRenderingPreview else {
            scheduleLivePreviewFrameRefresh()
            return
        }

        pendingLivePreviewFrameRefresh = false
        livePreviewFrameRefreshInFlight = true
        lastLivePreviewFrameRefresh = CFAbsoluteTimeGetCurrent()
        let target = clampedPlayableTime(currentTime)
        player.currentItem?.cancelPendingSeeks()
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.livePreviewFrameRefreshInFlight = false
                guard self.pendingLivePreviewFrameRefresh,
                    !self.isScrubbing,
                    !self.isPlaying
                else { return }
                self.scheduleLivePreviewFrameRefresh()
            }
        }
    }

    private func livePreviewRefreshInterval() -> TimeInterval {
        let targetFrameRate = min(max(Double(project.renderSettings.frameRate), 30), 60)
        let baseInterval = 1.0 / targetFrameRate
        let complexity = livePreviewComplexityScore()
        switch complexity {
        case 0...5:
            return baseInterval
        case 6...11:
            return max(baseInterval, 1.0 / 45.0)
        case 12...20:
            return max(baseInterval, 1.0 / 30.0)
        default:
            return max(baseInterval, 1.0 / 24.0)
        }
    }

    private func livePreviewComplexityScore() -> Int {
        var score = 0
        for track in project.tracks {
            guard !track.isMuted,
                track.kind == .visual || track.kind == .shape || track.kind == .text
            else { continue }

            for item in track.items where item.timelineStart <= currentTime && item.timelineEnd > currentTime {
                score += livePreviewComplexityScore(for: item)
            }
        }
        return score
    }

    private func livePreviewComplexityScore(for item: TimelineItem) -> Int {
        guard let visuals = item.editableVisuals else { return 1 }
        let transform = visuals.transform
        var keyframeCost = 0
        keyframeCost += transform.positionX.keyframes.count
        keyframeCost += transform.positionY.keyframes.count
        keyframeCost += transform.scale.keyframes.count
        keyframeCost += transform.rotationDegrees.keyframes.count
        keyframeCost += transform.opacity.keyframes.count
        let effectCost = visuals.effectStack.effects.count * 3
        let maskCost = visuals.mask == nil ? 0 : 2
        let backgroundRemovalCost = visuals.backgroundRemoval == nil ? 0 : 4
        return 1 + effectCost + min(keyframeCost, 8) + maskCost + backgroundRemovalCost
    }

    func persist() {
        autosaveTask?.cancel()
        let snapshot = project
        let projectID = projectID
        projectSession.saveState = .saving
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self else { return }
                try await self.projectStore.repository.save(
                    ProjectContent(editorProject: snapshot),
                    projectID: projectID
                )
                guard !Task.isCancelled else { return }
                self.projectStore.recordSavedContent(
                    ProjectContent(editorProject: snapshot),
                    projectID: projectID
                )
                self.scheduleProjectPosterRender(for: snapshot)
                self.projectSession.saveState = .saved(Date())
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                let message = error.localizedDescription
                self.projectSession.saveState = .failed(message)
                self.errorMessage = message
                AppLogger.persistence.error(
                    "Failed to autosave project content: \(message, privacy: .public)"
                )
            }
        }
    }

    func installTimeObserver() {
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
                if self.isPlaying, !self.isScrubbing, !self.isRenderingPreview {
                    self.updateCurrentTime(self.clampedTimelineTime(seconds))
                }
                if self.isPlaying, self.duration > 0, seconds >= self.lastPlayableTime {
                    self.player?.pause()
                    self.isPlaying = false
                    self.seekPlayer(to: self.lastPlayableTime, exact: true)
                }
                if let graphSegment = self.graphSegment,
                    let clip = self.project.clip(id: graphSegment.clipID)
                {
                    let graphEnd = clip.timelineStart + graphSegment.endTime
                    if seconds >= graphEnd - 0.012 {
                        self.player?.pause()
                        self.isPlaying = false
                        self.seek(to: graphEnd)
                    }
                }
            }
        }
    }

    func updateHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func updateCurrentTime(_ time: Double) {
        currentTime = clampedTimelineTime(time)
    }

    func updateSelection(clipID: UUID?, trackID: UUID?) {
        selectedClipID = clipID
        selectedTrackID = trackID
    }

    func isTimeInside(_ clip: TimelineClip) -> Bool {
        guard let item = project.item(id: clip.id) else {
            return currentTime >= clip.timelineStart && currentTime < clip.timelineEnd
        }
        return currentTime >= item.timelineStart && currentTime < item.timelineEnd
    }

    func timelinePlacementDuration(for clip: TimelineClip) -> Double {
        project.item(id: clip.id)?.placementDuration ?? clip.sourceRange.duration
    }

    func timelineLocalTime(for clip: TimelineClip) -> Double {
        min(
            max(currentTime - clip.timelineStart, 0),
            timelinePlacementDuration(for: clip)
        )
    }

    func nearestVisibleTime(for clip: TimelineClip) -> Double {
        let duration = timelinePlacementDuration(for: clip)
        let timelineEnd = clip.timelineStart + duration
        let epsilon = min(max(duration * 0.05, 0.001), clipRevealEpsilon)
        if currentTime < clip.timelineStart {
            return min(clip.timelineStart + epsilon, max(clip.timelineStart, timelineEnd - epsilon))
        }
        return max(clip.timelineStart, timelineEnd - epsilon)
    }

    func incrementTimelineContentRevision() {
        timelineContentRevision &+= 1
    }

    func setPreviewQualityForInteraction(_ interactive: Bool) {
        previewQuality = interactive ? .interactive : .balanced
    }

    func scheduleProjectPosterRender(for snapshot: EditorProject) {
        guard let signature = snapshot.projectPosterSignatureData,
            signature != lastProjectPosterSignature
        else { return }
        lastProjectPosterSignature = signature
        projectPosterTask?.cancel()
        projectPosterTask = Task { [projectStore, projectID] in
            do {
                try await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                try await ProjectPosterService.shared.renderPoster(
                    for: snapshot,
                    outputURL: projectStore.posterURL(for: projectID)
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    projectStore.notePosterChanged()
                }
            } catch is CancellationError {
                return
            } catch ProjectPosterError.noVisualContent {
                await MainActor.run {
                    projectStore.removePoster(for: projectID)
                }
            } catch {
                AppLogger.rendering.warning(
                    "Failed to render project poster: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}

private struct ProjectPosterSignature: Codable {
    struct Track: Codable {
        let id: UUID
        let kind: TrackKind
        let isMuted: Bool
        let items: [TimelineItem]
    }

    let renderSettings: RenderSettings
    let tracks: [Track]
}

private extension EditorProject {
    var projectPosterSignatureData: Data? {
        let signature = ProjectPosterSignature(
            renderSettings: renderSettings,
            tracks: tracks
                .filter { $0.kind == .visual || $0.kind == .shape || $0.kind == .text }
                .map {
                    ProjectPosterSignature.Track(
                        id: $0.id,
                        kind: $0.kind,
                        isMuted: $0.isMuted,
                        items: $0.items.filter { item in
                            switch item {
                            case .media(let media):
                                media.mediaType != .audio
                            case .shape, .text:
                                true
                            case .caption, .adjustment, .compound:
                                false
                            }
                        }
                    )
                }
        )
        return try? JSONEncoder().encode(signature)
    }
}
