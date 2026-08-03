// Imported-media insertion, persistence, mutation history, and selection validation.

import AVFoundation
import Foundation
import os

private let previewRenderMetricsLog = OSLog(
    subsystem: "com.moysoft.motionary",
    category: .pointsOfInterest
)

/// Classifies a value-model mutation without comparing the track graph twice.
///
/// Interactive samples overwhelmingly mutate `tracks`. Evaluate that graph
/// once and use the result both for the project dirty guard and cache
/// invalidation. Only a metadata-only mutation pays for the remaining project
/// field comparisons.
private struct ProjectMutationDirtyState {
    let projectChanged: Bool
    let tracksChanged: Bool

    init(previous: EditorProject, current: EditorProject) {
        tracksChanged = previous.tracks != current.tracks
        projectChanged =
            tracksChanged
            || previous.id != current.id
            || previous.schemaVersion != current.schemaVersion
            || previous.title != current.title
            || previous.renderSettings != current.renderSettings
            || previous.mediaLibrary != current.mediaLibrary
            || previous.sequences != current.sequences
            || previous.itemLinks != current.itemLinks
            || previous.createdAt != current.createdAt
            || previous.updatedAt != current.updatedAt
    }
}

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
            let isTransientInteractiveEdit = interactiveEditSnapshot != nil
            let previousTracks = project.tracks
            let previousSelectedTrackID = selectedTrackID
            var after = project
            mutation(&after)
            if !isTransientInteractiveEdit {
                after.renumberTracks()
                after.synchronizeMediaLibrary()
            }
            let dirtyState = ProjectMutationDirtyState(
                previous: project,
                current: after
            )
            guard dirtyState.projectChanged else { return }
            if !isTransientInteractiveEdit {
                publishProjectChange()
            }
            project = after
            refreshSelectedTimelineRange()
            let transientScope: TimelineInvalidationScope
            if isTransientInteractiveEdit {
                let trackIDs = Set([previousSelectedTrackID, selectedTrackID].compactMap { $0 })
                transientScope = trackIDs.isEmpty
                    ? .all
                    : .tracks(trackIDs, timeRange: selectedTimelineRange.map {
                        $0.lowerBound...$0.upperBound
                    })
            } else {
                transientScope = .comparing(
                    previous: previousTracks,
                    current: project.tracks
                )
            }
            if dirtyState.tracksChanged {
                markTimelineEvaluationChanged()
                invalidatePreviewCanvasIfNeeded(
                    transientScope,
                    previousTracks: previousTracks,
                    currentTracks: project.tracks
                )
                if !isTransientInteractiveEdit {
                    invalidateTimelineCaches(transientScope)
                }
            }
            if refreshTimeline {
                if isTransientInteractiveEdit {
                    deferTimelineContentInvalidation(transientScope)
                } else {
                    invalidateTimelineContent(transientScope)
                }
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

    /// Applies system-derived metadata without letting an asynchronous result
    /// become part of an in-flight user gesture's undo diff. The same mutation
    /// is rebased into the gesture baseline.
    func mutateDerivedProjectData(
        persistChanges: Bool = true,
        _ mutation: (inout EditorProject) -> Void
    ) {
        let previousTracks = project.tracks
        var after = project
        mutation(&after)
        guard after != project else { return }

        publishProjectChange()
        project = after
        if var baseline = interactiveEditSnapshot {
            mutation(&baseline)
            interactiveEditSnapshot = baseline
        }
        if previousTracks != project.tracks {
            let scope = TimelineInvalidationScope.comparing(
                previous: previousTracks,
                current: project.tracks
            )
            markTimelineEvaluationChanged()
            invalidatePreviewCanvasIfNeeded(
                scope,
                previousTracks: previousTracks,
                currentTracks: project.tracks
            )
            invalidateTimelineCaches(scope)
        }
        refreshSelectedTimelineRange()
        if persistChanges {
            persist()
        }
    }

    func perform(
        _ command: AnyEditorCommand,
        recordHistory: Bool = true,
        persistChanges: Bool = true,
        touchUpdatedAt: Bool = true,
        refreshTimeline: Bool = true
    ) {
        var precedingInteractiveRenderInvalidation: EditorInvalidation = []
        var isTransientInteractiveEdit =
            interactiveEditSnapshot != nil
            && !recordHistory
            && !persistChanges
            && !touchUpdatedAt
        if let interactiveEditSnapshot, !isTransientInteractiveEdit {
            // External/user commands get their own undo boundary instead of
            // contaminating the gesture snapshot that was already in flight.
            // Its render flags are carried into the command's single rebuild;
            // scheduling two tasks here would let the latter cancel topology
            // or audio work required by the just-committed gesture.
            precedingInteractiveRenderInvalidation = project.renderInvalidation(
                comparedTo: interactiveEditSnapshot
            )
            finishInteractiveEdit(rebuild: false, delayRebuild: false)
            isTransientInteractiveEdit = false
        }
        let previousTracks = project.tracks
        let previousSelectedTrackID = selectedTrackID
        if !isTransientInteractiveEdit {
            publishProjectChange()
        }
        command.apply(to: &project)
        if !isTransientInteractiveEdit,
            command.invalidation.contains(.persistence)
                || command.invalidation.contains(.compositionTopology)
        {
            project.synchronizeMediaLibrary()
        }
        if !isTransientInteractiveEdit {
            project.renumberTracks()
        }
        let tracksChanged = previousTracks != project.tracks
        refreshSelectedTimelineRange()
        let scope: TimelineInvalidationScope
        if isTransientInteractiveEdit {
            let trackIDs = Set([previousSelectedTrackID, selectedTrackID].compactMap { $0 })
            scope = trackIDs.isEmpty
                ? .all
                : .tracks(trackIDs, timeRange: selectedTimelineRange.map {
                    $0.lowerBound...$0.upperBound
                })
        } else {
            scope = .comparing(previous: previousTracks, current: project.tracks)
        }
        if tracksChanged {
            markTimelineEvaluationChanged()
            invalidatePreviewCanvasIfNeeded(
                scope,
                previousTracks: previousTracks,
                currentTracks: project.tracks
            )
            if !isTransientInteractiveEdit {
                invalidateTimelineCaches(scope)
            }
        }
        updateCurrentTime(clampedTimelineTime(currentTime))
        if refreshTimeline {
            if isTransientInteractiveEdit {
                deferTimelineContentInvalidation(scope)
            } else {
                invalidateTimelineContent(scope)
            }
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
        let combinedRenderInvalidation =
            command.invalidation.union(precedingInteractiveRenderInvalidation)
        if !combinedRenderInvalidation
            .intersection([.previewFrame, .compositionTopology, .audioMix])
            .isEmpty
        {
            schedulePreviewRebuild(
                seekTo: currentTime,
                invalidation: combinedRenderInvalidation
            )
        }
    }

    func schedulePreviewRebuild(
        seekTo time: Double? = nil,
        delay: Bool = true,
        invalidation: EditorInvalidation = [.previewFrame]
    ) {
        var effectiveInvalidation = invalidation
        if previewRecoveryCircuitIsOpen {
            resetPreviewRecoveryCircuit()
            effectiveInvalidation.formUnion([.previewFrame, .compositionTopology, .audioMix])
        }

        if isScrubbing {
            deferredPreviewInvalidation.formUnion(effectiveInvalidation)
            return
        }

        if rebuildTask != nil, effectiveInvalidation.contains(.previewFrame) {
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
                invalidation: effectiveInvalidation,
                generation: generation
            )
        }
    }

    func scheduleInteractivePreviewRebuild(
        invalidation: EditorInvalidation
    ) {
        // A volume or audio-keyframe gesture only changes one retained
        // composition track. Rebuilding every input parameter, replacing the
        // preview graph, and seeking the player at gesture frequency causes
        // audible discontinuities and blocks unrelated editor interaction.
        if invalidation == [.audioMix],
            let itemID = selectedTimelineItemID,
            let item = project.item(id: itemID),
            case .media = item,
            player?.currentItem != nil,
            renderService.canPrepareInteractiveAudioMix(for: itemID)
        {
            if rebuildTask != nil {
                rebuildTask?.cancel()
                rebuildTask = nil
                previewGeneration &+= 1
                isRenderingPreview = false
            }
            scheduleLiveAudioPreviewRefresh(for: itemID)
            return
        }

        setPreviewQualityForInteraction(true)

        // Descriptor compilation, AVVideoComposition replacement, and a
        // synchronized player seek are far too expensive for a 60 Hz
        // inspector gesture. Purely visual edits can be resolved by the
        // compositor from an immutable live override while retaining the
        // existing AVFoundation topology and every enabled effect.
        if invalidation == [.previewFrame],
            let itemID = selectedTimelineItemID,
            let item = project.item(id: itemID),
            let visuals = item.editableVisuals
        {
            // A rebuild started before this mutation only contains the older
            // descriptor state. Cancel its generation so its completion
            // cannot clear or present over the newer live override.
            if rebuildTask != nil {
                rebuildTask?.cancel()
                rebuildTask = nil
                previewGeneration &+= 1
                isRenderingPreview = false
            }

            let shape: ClipShape?
            let text: TextTimelineItem?
            switch item {
            case .shape(let shapeItem):
                shape = shapeItem.shape
                text = nil
            case .text(let textItem):
                shape = nil
                text = textItem
            default:
                shape = nil
                text = nil
            }
            renderService.livePreviewState.setVisuals(
                visuals,
                shape: shape,
                text: text,
                for: itemID
            )
            pendingLiveVisualOverrideItemIDs.insert(itemID)
            scheduleLivePreviewFrameRefresh()
            return
        }

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

    /// Coalesces audio-control samples to a 30 Hz control rate while allowing
    /// at most one selected-track envelope preparation in flight. Unlike the
    /// generic preview path this never rebuilds video descriptors or seeks the
    /// player, and it keeps the visual preview at its current quality.
    private func scheduleLiveAudioPreviewRefresh(for itemID: UUID) {
        pendingLiveAudioPreviewItemID = itemID
        guard liveAudioPreviewTask == nil else { return }

        let interval = 1.0 / 30.0
        let elapsed = CFAbsoluteTimeGetCurrent() - lastLiveAudioPreviewRefresh
        let remaining = max(interval - elapsed, 0)
        liveAudioPreviewTaskGeneration &+= 1
        let taskGeneration = liveAudioPreviewTaskGeneration
        liveAudioPreviewTask = Task { [weak self] in
            if remaining > 0 {
                do {
                    try await Task.sleep(for: .seconds(remaining))
                } catch {
                    guard let self else { return }
                    self.finishLiveAudioPreviewTask(generation: taskGeneration)
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            guard let pendingItemID = self.pendingLiveAudioPreviewItemID else {
                self.finishLiveAudioPreviewTask(generation: taskGeneration)
                return
            }
            self.pendingLiveAudioPreviewItemID = nil
            let projectSnapshot = self.project
            let prepared = await self.renderService.prepareInteractiveAudioMix(
                for: projectSnapshot,
                itemID: pendingItemID
            )
            guard !Task.isCancelled else {
                self.finishLiveAudioPreviewTask(generation: taskGeneration)
                return
            }

            var installed = false
            if let prepared,
                let currentItem = self.project.item(id: prepared.itemID),
                case .media(let currentMediaItem) = currentItem,
                currentMediaItem.visuals.volume == prepared.volume,
                self.renderService.installInteractiveAudioMix(prepared)
            {
                self.player?.currentItem?.audioMix = prepared.audioMix
                self.lastLiveAudioPreviewRefresh = CFAbsoluteTimeGetCurrent()
                installed = true
            }

            // A newer gesture sample can arrive while the actor samples the
            // envelope. Never present the stale result; consume the latest
            // model value in the next bounded pass instead.
            if !installed,
                self.pendingLiveAudioPreviewItemID == nil,
                let currentItem = self.project.item(id: pendingItemID),
                case .media = currentItem,
                self.renderService.canPrepareInteractiveAudioMix(for: pendingItemID)
            {
                self.pendingLiveAudioPreviewItemID = pendingItemID
            }

            self.finishLiveAudioPreviewTask(generation: taskGeneration)
        }
    }

    /// Releases only the slot owned by `generation`. A cancelled task can
    /// resume after an actor hop; without this guard it could clear the slot of
    /// a newer gesture and accidentally permit concurrent mix preparations.
    private func finishLiveAudioPreviewTask(generation: Int) {
        guard generation == liveAudioPreviewTaskGeneration else { return }
        liveAudioPreviewTask = nil
        if let latestItemID = pendingLiveAudioPreviewItemID {
            scheduleLiveAudioPreviewRefresh(for: latestItemID)
        }
    }

    func cancelInteractivePreviewRebuild(cancelLivePreviewRefresh: Bool = true) {
        interactivePreviewThrottleTask?.cancel()
        interactivePreviewThrottleTask = nil
        pendingInteractivePreviewInvalidation = []
        lastInteractivePreviewRebuild = 0
        liveAudioPreviewTask?.cancel()
        liveAudioPreviewTask = nil
        pendingLiveAudioPreviewItemID = nil
        liveAudioPreviewTaskGeneration &+= 1
        if cancelLivePreviewRefresh {
            livePreviewFrameRefreshTask?.cancel()
            livePreviewFrameRefreshTask = nil
            pendingLivePreviewFrameRefresh = false
            livePreviewFrameRefreshInFlight = false
            lastLivePreviewFrameRefresh = 0
        }
    }

    /// Clears only descriptor-backed visual fields. Direct canvas transforms
    /// and source visibility are independent handoff state and must survive
    /// until their own fresh-frame presentation completes.
    func clearPendingLiveVisualOverrides() {
        let itemIDs = pendingLiveVisualOverrideItemIDs
        pendingLiveVisualOverrideItemIDs.removeAll(keepingCapacity: true)
        for itemID in itemIDs {
            renderService.livePreviewState.clearVisuals(for: itemID)
        }
    }

    func beginLivePreviewInteraction() {
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
        setPreviewQualityForInteraction(true)
        if let hidden {
            renderService.livePreviewState.setTransform(transform, hidden: hidden, for: itemID)
        } else {
            renderService.livePreviewState.setTransform(transform, for: itemID)
        }
        if immediate {
            livePreviewFrameRefreshTask?.cancel()
            livePreviewFrameRefreshTask = nil
            pendingLivePreviewFrameRefresh = true
            guard player?.currentItem != nil else {
                pendingLivePreviewFrameRefresh = false
                schedulePreviewRebuild(
                    seekTo: currentTime,
                    delay: false,
                    invalidation: [.previewFrame]
                )
                return
            }
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
            renderService.livePreviewState.clearOverride(for: itemID)
            pendingLiveVisualOverrideItemIDs.remove(itemID)
        } else {
            renderService.livePreviewState.removeAll()
            pendingLiveVisualOverrideItemIDs.removeAll(keepingCapacity: true)
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

    /// Moves the live canvas handoff to balanced presentation without
    /// starting another descriptor build. The interaction commit already
    /// owns exactly one canonical rebuild.
    func prepareLivePreviewCommitPresentation(for itemID: UUID?) {
        setPreviewQualityForInteraction(false)
        if let itemID {
            // A SwiftUI raster proxy may still cover the player until the
            // fresh-frame acknowledgement, but the canonical compositor frame
            // itself must contain the source. Keep only the live transform.
            showLivePreviewSourcePreservingTransform(for: itemID, refresh: false)
        }
    }

    /// Releases the live transform only after `rebuildPreview` has presented
    /// the committed descriptor generation and advanced
    /// `previewContentRevision`. The old fixed-delay clear could expose the
    /// stale descriptor on complex timelines.
    func completeLivePreviewCommitPresentation(for itemID: UUID?) {
        showLivePreviewSource(for: itemID, refresh: false)
        setPreviewQualityForInteraction(false)
    }

    func clearLivePreviewTransform(for itemID: UUID?, refresh: Bool = true) {
        if let itemID {
            renderService.livePreviewState.clearTransform(for: itemID)
        } else {
            renderService.livePreviewState.removeAll()
            pendingLiveVisualOverrideItemIDs.removeAll(keepingCapacity: true)
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
        Task { [weak self, weak player] in
            guard let self, let player else { return }
            let didSeek = await self.boundedSeek(
                player: player,
                to: target,
                toleranceBefore: .zero,
                toleranceAfter: .zero,
                timeoutNanoseconds: 900_000_000
            )
            guard self.player === player else { return }
            self.livePreviewFrameRefreshInFlight = false
            if !didSeek {
                self.schedulePreviewRecovery(
                    reason: .seekTimeout,
                    resumePlayback: false
                )
                return
            }
            guard self.pendingLivePreviewFrameRefresh,
                !self.isScrubbing,
                !self.isPlaying
            else { return }
            self.scheduleLivePreviewFrameRefresh()
        }
    }

    private func livePreviewRefreshInterval() -> TimeInterval {
        let targetFrameRate = min(max(Double(project.renderSettings.frameRate), 30), 60)
        let baseInterval = 1.0 / targetFrameRate
        let complexity = cachedTimelineEvaluationIndex(
            allowStale: interactiveEditSnapshot != nil
        ).generatedLayerCost(at: currentTime)
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
            MainActor.assumeIsolated {
                let seconds = CMTimeGetSeconds(time)
                if self.isPlaying, !self.isScrubbing, !self.isRenderingPreview {
                    self.updateCurrentTime(self.clampedTimelineTime(seconds))
                }
                if self.isPlaying, self.duration > 0, seconds >= self.lastPlayableTime {
                    self.player?.pause()
                    self.stopPlaybackWatchdog()
                    self.isPlaying = false
                    self.seekPlayer(to: self.lastPlayableTime, exact: true)
                }
                if let graphSegment = self.graphSegment,
                    let item = self.indexedTimelineItem(id: graphSegment.clipID)
                {
                    let graphEnd = item.timelineStart + graphSegment.endTime
                    if seconds >= graphEnd - 0.012 {
                        self.player?.pause()
                        self.stopPlaybackWatchdog()
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
        guard let item = indexedTimelineItem(id: clip.id) else {
            return currentTime >= clip.timelineStart && currentTime < clip.timelineEnd
        }
        return currentTime >= item.timelineStart && currentTime < item.timelineEnd
    }

    func timelinePlacementDuration(for clip: TimelineClip) -> Double {
        indexedTimelineItem(id: clip.id)?.placementDuration ?? clip.sourceRange.duration
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
        invalidateTimelineContent(.all)
    }

    func setPreviewQualityForInteraction(_ interactive: Bool) {
        previewQuality = interactive ? .interactive : .balanced
        renderService.livePreviewState.setInteractiveQualityOverride(interactive)
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
