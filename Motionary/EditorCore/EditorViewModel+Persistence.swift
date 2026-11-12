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
            || previous.exportSettings != current.exportSettings
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
            after.renderSettings = RenderSettings(
                size: naturalSize,
                frameRate: after.renderSettings.frameRate
            )
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
            after.synchronizeExportFrameRate()
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
        after.synchronizeExportFrameRate()
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
        _ command: any EditorCommand,
        recordHistory: Bool = true,
        persistChanges: Bool = true,
        touchUpdatedAt: Bool = true,
        refreshTimeline: Bool = true,
        affectsPreviewGeometry: Bool = true
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
            if !pendingLiveVisualOverrideItemIDs.isEmpty {
                precedingInteractiveRenderInvalidation.insert(.previewFrame)
            }
            finishInteractiveEdit(rebuild: false, delayRebuild: false)
            isTransientInteractiveEdit = false
        }
        let previousTracks = project.tracks
        let previousSelectedTrackID = selectedTrackID
        if !isTransientInteractiveEdit {
            publishProjectChange()
        }
        let replacement = isTransientInteractiveEdit ? command as? ReplaceClipCommand : nil
        if replacement.map(applyInteractiveClipReplacement) != true {
            command.apply(to: &project)
            project.synchronizeExportFrameRate()
        }
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
            if affectsPreviewGeometry {
                invalidatePreviewCanvasIfNeeded(
                    scope,
                    previousTracks: previousTracks,
                    currentTracks: project.tracks
                )
            }
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
            undoStack.append(command as? AnyEditorCommand ?? AnyEditorCommand(command))
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

    /// Keep the retained live frame while a workspace owns vertical scrolling.
    /// Commits still record undo immediately; graph installation and disk/poster
    /// work resume once after both dragging and scroll deceleration have ended.
    func setWorkspaceScrolling(_ active: Bool, owner: UUID) {
        if active {
            guard workspaceScrollOwners.insert(owner).inserted, workspaceScrollOwners.count == 1 else { return }
            rebuildTask?.cancel()
            rebuildTask = nil
            previewGeneration &+= 1
            isRenderingPreview = false
            cancelInteractivePreviewRebuild()
            if autosaveTask != nil {
                autosaveTask?.cancel()
                autosaveTask = nil
                workspacePersistencePending = true
            }
            if projectPosterTask != nil {
                projectPosterTask?.cancel()
                projectPosterTask = nil
                lastProjectPosterSignature = nil
                workspacePersistencePending = true
            }
        } else {
            guard workspaceScrollOwners.remove(owner) != nil, workspaceScrollOwners.isEmpty else { return }
            if workspacePersistencePending {
                workspacePersistencePending = false
                persist()
            }
            if !pendingPreviewInvalidation.isEmpty {
                schedulePreviewRebuild(seekTo: currentTime, delay: false, invalidation: [])
            } else if !pendingLiveVisualOverrideItemIDs.isEmpty {
                scheduleLivePreviewFrameRefresh()
            }
        }
    }

    func schedulePreviewRebuild(
        seekTo time: Double? = nil,
        delay: Bool = true,
        invalidation: EditorInvalidation = [.previewFrame]
    ) {
        var effectiveInvalidation = invalidation.union(pendingPreviewInvalidation)
        if previewRecoveryCircuitIsOpen {
            resetPreviewRecoveryCircuit()
            effectiveInvalidation.formUnion([.previewFrame, .compositionTopology, .audioMix])
        }

        if effectiveInvalidation.contains(.compositionTopology),
            !pendingPreviewInvalidation.contains(.compositionTopology)
        {
            // Hold the displayed frame through the AVPlayerItem replacement.
            // The old cache itself must be invalidated before the next scrub.
            if !isPlaying, livePreviewPresentation.frame == nil {
                let frameTime = livePreviewPresentationTime(clampedPlayableTime(currentTime))
                if let frame = renderService.livePreviewState.cachedFrame(
                    at: frameTime, sessionID: previewRenderSessionID)
                {
                    livePreviewPresentation.setFrame(frame, at: frameTime)
                }
            }
            renderService.livePreviewState.invalidateComposedFrames()
            renderService.livePreviewState.clearPausedFrameRenderer()
            invalidateLivePreviewPresentation(preservingFrame: true)
        }
        pendingPreviewInvalidation.formUnion(effectiveInvalidation)
        guard !previewIsSuspended, workspaceScrollOwners.isEmpty else { return }
        if isScrubbing, !effectiveInvalidation.contains(.compositionTopology) {
            deferredPreviewInvalidation.formUnion(effectiveInvalidation)
            return
        }

        if rebuildTask != nil, effectiveInvalidation.contains(.previewFrame) {
            os_signpost(.event, log: previewRenderMetricsLog, name: "Dropped Preview Frame")
        }
        rebuildTask?.cancel()
        previewGeneration &+= 1
        let generation = previewGeneration
        let commandGeneration = playbackCommandGeneration
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
            guard !Task.isCancelled,
                !self.isScrubbing || effectiveInvalidation.contains(.compositionTopology) else { return }
            await self.rebuildPreview(
                seekTo: time,
                invalidation: effectiveInvalidation,
                generation: generation,
                commandGeneration: commandGeneration
            )
        }
    }

    func scheduleInteractivePreviewRebuild(
        invalidation: EditorInvalidation
    ) {
        guard workspaceScrollOwners.isEmpty else {
            pendingPreviewInvalidation.formUnion(invalidation)
            return
        }
        // A volume or audio-keyframe gesture only changes one retained
        // composition track. Rebuilding every input parameter, replacing the
        // preview graph, and seeking the player at gesture frequency causes
        // audible discontinuities and blocks unrelated editor interaction.
        if invalidation == [.audioMix],
            let itemID = selectedTimelineItemID,
            let item = indexedTimelineItem(id: itemID),
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
            let item = indexedTimelineItem(id: itemID),
            let visuals = item.editableVisuals
        {
            guard renderService.canApplyLiveDepth(in: visuals.effectStack, to: itemID) else {
                if rebuildTask == nil {
                    schedulePreviewRebuild(seekTo: currentTime, delay: false, invalidation: invalidation)
                }
                return
            }
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
            livePreviewSeekTask?.cancel()
            livePreviewSeekTask = nil
            livePreviewFrameRefreshGeneration &+= 1
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

    func scheduleLivePreviewFrameRefresh() {
        guard !previewIsSuspended, workspaceScrollOwners.isEmpty else { return }
        setPreviewQualityForInteraction(true)
        guard !isScrubbing else { return }
        pendingLivePreviewFrameRefresh = true

        // Input and GPU completion drive this path. Project frame rate and
        // layer count must not throttle a 60/120 Hz canvas gesture. While a
        // frame is in flight, keep only the newest sample; its completion
        // immediately consumes that sample without a sleep/display-cycle hop.
        guard !livePreviewFrameRefreshInFlight else { return }
        guard isRenderingPreview else {
            livePreviewFrameRefreshTask?.cancel()
            livePreviewFrameRefreshTask = nil
            issueLivePreviewFrameRefresh()
            return
        }

        // Only an actual composition rebuild needs polling. The live GPU
        // path itself never waits on a timer.
        guard livePreviewFrameRefreshTask == nil else { return }
        livePreviewFrameRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(8))
            guard !Task.isCancelled, let self else { return }
            self.livePreviewFrameRefreshTask = nil
            self.scheduleLivePreviewFrameRefresh()
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
        livePreviewFrameRefreshGeneration &+= 1
        let generation = livePreviewFrameRefreshGeneration
        let graphGeneration = previewGeneration
        let renderSessionID = previewRenderSessionID
        livePreviewFrameRefreshInFlight = true
        lastLivePreviewFrameRefresh = CFAbsoluteTimeGetCurrent()
        let target = clampedPlayableTime(currentTime)
        // The exact composed frame may already be on hand under the current
        // live revision (e.g. rendered by a just-finished scrub step). Present
        // it directly instead of forcing a same-time re-seek below.
        if let fresh = renderService.livePreviewState.cachedFrame(
            at: livePreviewPresentationTime(target), sessionID: renderSessionID)
        {
            livePreviewFrameRefreshInFlight = false
            livePreviewPresentation.setFrame(fresh, at: livePreviewPresentationTime(target))
            if pendingLivePreviewFrameRefresh {
                scheduleLivePreviewFrameRefresh()
            }
            return
        }
        if renderService.livePreviewState.renderPausedFrame(
            at: livePreviewPresentationTime(target), sessionID: renderSessionID,
            completion: { [weak self, weak player] frame in
                Task { @MainActor in
                    guard let self, let player, self.player === player,
                        self.livePreviewFrameRefreshGeneration == generation
                    else { return }
                    self.livePreviewFrameRefreshInFlight = false
                    guard !self.isScrubbing, !self.isPlaying else { return }
                    guard self.previewGeneration == graphGeneration,
                        self.previewRenderSessionID == renderSessionID,
                        !self.isRenderingPreview
                    else {
                        // The graph changed while the GPU owned this frame.
                        // Keep the latest refresh instead of covering the new
                        // composition with this obsolete result.
                        self.pendingLivePreviewFrameRefresh = true
                        self.scheduleLivePreviewFrameRefresh()
                        return
                    }
                    // Frames are serialized: present completed work even when
                    // a newer sample is pending, so continuous gestures cannot
                    // starve presentation on a slower GPU.
                    if let frame {
                        self.livePreviewPresentation.setFrame(
                            frame,
                            at: self.livePreviewPresentationTime(target)
                        )
                    } else {
                        self.renderService.livePreviewState.clearPausedFrameRenderer()
                        self.pendingLivePreviewFrameRefresh = true
                    }
                    if self.pendingLivePreviewFrameRefresh {
                        self.scheduleLivePreviewFrameRefresh()
                    }
                }
            }
        ) { return }
        // Bootstrap a source-frame snapshot when AVPlayer has cached this time
        // or last rendered ahead during playback. Replacing the immutable
        // composition with a mutable copy forces AVPlayer to request the frame
        // at the unchanged presentation time again; the instruction stays the
        // same instance (see `copy(with:)`), so this allocates a shell, not a
        // second interval index. It is the last resort here: the paused GPU
        // path and the exact-cache hit above handle the common interaction
        // samples without it.
        if let item = player.currentItem,
            let composition = item.videoComposition?.mutableCopy() as? AVMutableVideoComposition {
            item.videoComposition = composition
        }
        player.currentItem?.cancelPendingSeeks()
        livePreviewSeekTask = Task { [weak self, weak player] in
            guard let self, let player else { return }
            defer {
                if self.livePreviewFrameRefreshGeneration == generation { self.livePreviewSeekTask = nil }
            }
            let didSeek = await self.boundedSeek(
                player: player,
                to: self.livePreviewPresentationTime(target),
                toleranceBefore: .zero,
                toleranceAfter: .zero,
                timeoutNanoseconds: 5_000_000_000
            )
            guard self.player === player,
                self.livePreviewFrameRefreshGeneration == generation
            else { return }
            self.livePreviewFrameRefreshInFlight = false
            guard !self.isScrubbing, !self.isPlaying else { return }
            guard self.previewGeneration == graphGeneration,
                self.previewRenderSessionID == renderSessionID,
                !self.isRenderingPreview
            else {
                self.pendingLivePreviewFrameRefresh = true
                self.scheduleLivePreviewFrameRefresh()
                return
            }
            if didSeek == .timedOut {
                self.schedulePreviewRecovery(
                    reason: .seekTimeout,
                    resumePlayback: false
                )
                return
            }
            if didSeek == .completed {
                // The refreshed AVPlayerLayer now owns the canonical frame.
                // A previously displayed direct-render frame would otherwise
                // remain opaque above it until the user scrubs or plays.
                self.livePreviewPresentation.frame = nil
            } else {
                // A cancelled seek has not satisfied the refresh request.
                self.pendingLivePreviewFrameRefresh = true
            }
            guard self.pendingLivePreviewFrameRefresh,
                !self.isScrubbing,
                !self.isPlaying
            else { return }
            self.scheduleLivePreviewFrameRefresh()
        }
    }

    func invalidateLivePreviewPresentation(preservingFrame: Bool = false) {
        livePreviewSeekTask?.cancel()
        livePreviewSeekTask = nil
        if preservingFrame {
            livePreviewPresentation.clearFramePreservingDisplay()
        } else {
            livePreviewPresentation.frame = nil
        }
        livePreviewFrameRefreshGeneration &+= 1
        livePreviewFrameRefreshTask?.cancel()
        livePreviewFrameRefreshTask = nil
        livePreviewFrameRefreshInFlight = false
        pendingLivePreviewFrameRefresh = false
    }

    func livePreviewPresentationTime(_ time: Double) -> Double {
        // Match the exact CMTime sent to AVPlayer, including sub-frame scrub
        // positions. Zero is an authored frame too: advancing it by one frame
        // changes cut/animation/source timing and can cross a short first clip.
        return CMTimeGetSeconds(CMTime(seconds: time, preferredTimescale: 600))
    }

    func persist() {
        guard workspaceScrollOwners.isEmpty else {
            workspacePersistencePending = true
            return
        }
        autosaveTask?.cancel()
        projectPosterTask?.cancel()
        projectPosterTask = nil
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

        // Progression only: the precise playhead clock is read directly from
        // the player by the preview canvas, so this observer publishes at most
        // once per project frame. Frame-quantized updates skip MainActor work
        // when the 50 ms tick lands inside the same frame as the previous
        // tick (the common case). Item-end delivery owns playback completion.
        var lastPublishedQuantizedTime = -1.0
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] _ in
            guard let self, let player else { return }
            MainActor.assumeIsolated {
                guard self.player === player, self.isPlaying, !self.isScrubbing,
                    !self.isRenderingPreview, !self.isPreviewSeekInFlight else { return }
                let seconds = CMTimeGetSeconds(player.currentTime())
                guard seconds.isFinite else { return }
                let frameDuration = 1 / Double(max(self.project.renderSettings.frameRate, 1))
                let quantized = floor(seconds / frameDuration) * frameDuration
                guard quantized != lastPublishedQuantizedTime else { return }
                lastPublishedQuantizedTime = quantized
                self.updateCurrentTime(self.clampedPlayableTime(seconds))
            }
        }
    }

    func finishPreviewPlayback(for item: AVPlayerItem) {
        guard let player, player.currentItem === item, isPlaying, !isScrubbing,
            !isPreviewSeekInFlight, CMTimeGetSeconds(player.currentTime()) >= lastPlayableTime
        else { return }
        player.pause()
        stopPlaybackWatchdog()
        updateCurrentTime(lastPlayableTime)
        isPlaying = false
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
        projectPosterTask?.cancel()
        projectPosterTask = Task(priority: .utility) { [weak self, projectStore, projectID] in
            do {
                try await Task.sleep(for: .milliseconds(900))
                let signature = await Task.detached(priority: .utility) { snapshot.projectPosterSignatureData }.value
                guard !Task.isCancelled, let self, let signature,
                    signature != self.lastProjectPosterSignature
                else { return }
                projectStore.schedulePosterRender(for: snapshot, projectID: projectID)
                self.lastProjectPosterSignature = signature
            } catch is CancellationError {
                return
            } catch {
                AppLogger.rendering.warning(
                    "Failed to schedule project poster: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}

private extension EditorProject {
    var projectPosterSignatureData: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(ProjectContent(editorProject: self))
    }
}
