// Editor lifecycle, playback, seeking, scrubbing, and undo history.

import AVFoundation

extension EditorViewModel {
    func start() {
        installEffectRenderDiagnosticsHandler()
        EditorAudioSession.configurePlayback()
        TimelineCacheLifecycle.installMemoryWarningHandler()
        Task {
            await TimelineThumbnailTileCache.shared.setActiveProject(projectID)
        }
        repairStoredMediaReferences()
        _ = prepareEnabledBackgroundRemovalArtifactsOnOpen()
        // Opening is not an active gesture. Build one stable balanced graph
        // instead of installing an interactive composition and replacing it
        // again while AVPlayer is still servicing its first frame requests.
        previewQuality = .balanced
        schedulePreviewRebuild(
            seekTo: 0,
            delay: false,
            invalidation: [.previewFrame, .compositionTopology, .audioMix]
        )
        persist()
    }

    func stop() {
        removeEffectRenderDiagnosticsHandler()
        let content = ProjectContent(editorProject: project)
        autosaveTask?.cancel()
        projectPosterTask?.cancel()
        projectPosterTask = nil
        interactivePreviewThrottleTask?.cancel()
        interactivePreviewThrottleTask = nil
        livePreviewFrameRefreshTask?.cancel()
        livePreviewFrameRefreshTask = nil
        liveAudioPreviewTask?.cancel()
        liveAudioPreviewTask = nil
        pendingLiveAudioPreviewItemID = nil
        liveAudioPreviewTaskGeneration &+= 1
        renderService.livePreviewState.removeAll()
        pendingLiveVisualOverrideItemIDs.removeAll(keepingCapacity: true)
        autosaveTask = Task { [projectStore, projectID] in
            try? await projectStore.repository.save(content, projectID: projectID)
        }
        Task {
            await TimelineThumbnailTileCache.shared.removeAll()
            await TimelineAudioWaveformCache.shared.removeAll()
            await MediaAssetCache.shared.removeAll()
        }
        rebuildTask?.cancel()
        rebuildTask = nil
        previewRecoveryTask?.cancel()
        previewRecoveryTask = nil
        stopPlaybackWatchdog()
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        importTask?.cancel()
        importTask = nil
        exportTask?.cancel()
        exportTask = nil
        analysisTask?.cancel()
        analysisTask = nil
        analysisState = nil
        isImporting = false
        isExporting = false
        pendingScrubSeekTime = nil
        isScrubSeekInFlight = false
        lastIssuedScrubSeekTime = nil
        scrubSeekLatencyEstimate = 0
        scrubSessionGeneration &+= 1
        scrubSeekGeneration &+= 1
        playbackCommandGeneration &+= 1
        lastScrubUIUpdate = 0
        lastLivePreviewFrameRefresh = 0
        lastLiveAudioPreviewRefresh = 0
        livePreviewFrameRefreshInFlight = false
        pendingLivePreviewFrameRefresh = false
        isRenderingPreview = false
        previewProgress = 0
        pendingPlaybackResumeAfterPreviewRebuild = false
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        replacePreviewPlayer(with: nil)
        isPlaying = false
    }

    func cancelLongRunningTask() {
        if analysisState != nil {
            analysisTask?.cancel()
            analysisTask = nil
            exportTask?.cancel()
            analysisState = nil
            return
        }
        if isExporting {
            exportTask?.cancel()
            exportTask = nil
            isExporting = false
            return
        }
        if isImporting {
            importTask?.cancel()
            importTask = nil
            isImporting = false
            return
        }
        if isRenderingPreview {
            rebuildTask?.cancel()
            rebuildTask = nil
            isRenderingPreview = false
            previewProgress = 0
            pendingPlaybackResumeAfterPreviewRebuild = false
        }
    }

    func togglePlayback() {
        guard let player else { return }
        playbackCommandGeneration &+= 1
        let commandGeneration = playbackCommandGeneration

        if pendingPlaybackResumeAfterPreviewRebuild {
            pendingPlaybackResumeAfterPreviewRebuild = false
            isPlaying = false
            player.pause()
            return
        }

        if isPlaying {
            pausePlaybackForUserCommand(player)
            return
        }

        cancelPendingPreviewRebuildBeforePlaybackStart()

        let endTolerance = max(keyframeTimeTolerance, 0.05)
        if duration > 0, currentTime >= max(duration - endTolerance, 0) {
            player.pause()
            player.currentItem?.cancelPendingSeeks()
            updateCurrentTime(0)
            Task { [weak self, weak player] in
                guard let self, let player else { return }
                let didSeek = await self.boundedSeek(
                    player: player,
                    to: 0,
                    toleranceBefore: .zero,
                    toleranceAfter: .zero,
                    timeoutNanoseconds: 700_000_000
                )
                guard self.player === player,
                    self.playbackCommandGeneration == commandGeneration
                else { return }
                guard didSeek else {
                    self.schedulePreviewRecovery(
                        reason: .seekTimeout,
                        resumePlayback: true
                    )
                    return
                }
                player.play()
                self.isPlaying = true
                self.startPlaybackWatchdog()
            }
            return
        }

        player.play()
        isPlaying = true
        startPlaybackWatchdog()
    }

    private func pausePlaybackForUserCommand(_ player: AVPlayer) {
        playbackCommandGeneration &+= 1
        scrubSessionGeneration &+= 1
        scrubSeekGeneration &+= 1

        stopPlaybackWatchdog()
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        isPlaying = false
        isScrubbing = false
        wasPlayingBeforeScrub = false

        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        pendingScrubSeekTime = nil
        isScrubSeekInFlight = false
        lastIssuedScrubSeekTime = nil
        lastScrubUIUpdate = 0
        scrubSeekLatencyEstimate = 0
        cancelInteractivePreviewRebuild()

        if rebuildTask != nil {
            deferredPreviewInvalidation.formUnion([
                .previewFrame,
                .compositionTopology,
                .audioMix,
            ])
            rebuildTask?.cancel()
            rebuildTask = nil
        }
        let invalidation = flushDeferredPreviewRebuild(
            seekTo: currentTime,
            includeGeneratedLayerQualityRestore: false
        )
        if invalidation.isEmpty, previewState.status == .cancelled {
            schedulePreviewRebuild(
                seekTo: currentTime,
                delay: false,
                invalidation: [.previewFrame]
            )
        }
        isScrubbing = false
        wasPlayingBeforeScrub = false
    }

    func startPlaybackWatchdog() {
        playbackWatchdogTask?.cancel()
        let generation = playbackCommandGeneration
        playbackWatchdogTask = Task { [weak self] in
            var lastObservedTime: Double?
            var lastProgressAt = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                let shouldContinue = await MainActor.run {
                    guard let self,
                        self.playbackCommandGeneration == generation,
                        self.isPlaying,
                        !self.isScrubbing,
                        !self.isRenderingPreview,
                        let player = self.player,
                        self.duration > 0
                    else { return false }
                    let seconds = CMTimeGetSeconds(player.currentTime())
                    guard seconds.isFinite else {
                        self.schedulePreviewRecovery(
                            reason: .playbackStalled,
                            resumePlayback: true
                        )
                        return false
                    }
                    if seconds >= self.lastPlayableTime - 0.05 {
                        return true
                    }
                    if let lastObservedTime,
                        seconds > lastObservedTime + 0.015
                    {
                        self.updateCurrentTime(self.clampedTimelineTime(seconds))
                        lastProgressAt = ContinuousClock.now
                    } else if lastObservedTime == nil {
                        lastProgressAt = ContinuousClock.now
                    } else if lastProgressAt.duration(to: ContinuousClock.now) > .milliseconds(1400) {
                        if self.lastPreviewRenderedFrameAt > 0 {
                            player.pause()
                            self.isPlaying = false
                            self.pendingPlaybackResumeAfterPreviewRebuild = false
                            self.stopPlaybackWatchdog()
                            return false
                        }
                        self.schedulePreviewRecovery(
                            reason: .playbackStalled,
                            resumePlayback: true
                        )
                        return false
                    }
                    lastObservedTime = seconds
                    return true
                }
                if !shouldContinue {
                    break
                }
            }
        }
    }

    func stopPlaybackWatchdog() {
        playbackWatchdogTask?.cancel()
        playbackWatchdogTask = nil
    }

    private func cancelPendingPreviewRebuildBeforePlaybackStart() {
        guard rebuildTask != nil, !isRenderingPreview else { return }
        rebuildTask?.cancel()
        rebuildTask = nil
        previewGeneration &+= 1
        previewProgress = 0
        if case .building = previewState.status {
            previewState.status = .idle
        }
    }

    func toggleGraphPlayback() {
        guard let segment = graphSegment,
            let item = indexedTimelineItem(id: segment.clipID)
        else {
            togglePlayback()
            return
        }
        let start = item.timelineStart + segment.startTime
        let end = item.timelineStart + segment.endTime
        if !isPlaying, currentTime >= end - keyframeTimeTolerance {
            seek(to: start)
        }
        togglePlayback()
    }

    func undo() {
        if interactiveEditSnapshot != nil {
            // Commit the gesture as its own history entry first. Undo then
            // targets exactly that edit, and the later gesture onEnded callback
            // becomes a harmless no-op instead of contaminating redo history.
            finishInteractiveEdit(rebuild: false, delayRebuild: false)
        }
        guard let command = undoStack.popLast() else { return }
        let retainedClipID = selectedClipID
        let previousTracks = project.tracks
        publishProjectChange()
        command.undo(on: &project)
        if previousTracks != project.tracks {
            markTimelineEvaluationChanged()
            invalidatePreviewCanvasIfNeeded(
                .comparing(previous: previousTracks, current: project.tracks),
                previousTracks: previousTracks,
                currentTracks: project.tracks
            )
        }
        redoStack.append(command)
        restoreSelectionIfPossible(retainedClipID)
        refreshSelectedTimelineRange()
        updateCurrentTime(clampedTimelineTime(currentTime))
        invalidateTimelineContent(
            .comparing(previous: previousTracks, current: project.tracks)
        )
        if graphSegment != nil {
            refreshGraphSegment()
        }
        updateHistoryFlags()
        persist()
        schedulePreviewRebuild(
            seekTo: clampedTimelineTime(currentTime),
            invalidation: command.invalidation
        )
    }

    func redo() {
        if interactiveEditSnapshot != nil {
            // A newly committed gesture intentionally invalidates the old redo
            // branch, matching ordinary editor history semantics.
            finishInteractiveEdit(rebuild: true, delayRebuild: false)
        }
        guard let command = redoStack.popLast() else { return }
        let retainedClipID = selectedClipID
        let previousTracks = project.tracks
        publishProjectChange()
        command.apply(to: &project)
        if previousTracks != project.tracks {
            markTimelineEvaluationChanged()
            invalidatePreviewCanvasIfNeeded(
                .comparing(previous: previousTracks, current: project.tracks),
                previousTracks: previousTracks,
                currentTracks: project.tracks
            )
        }
        undoStack.append(command)
        restoreSelectionIfPossible(retainedClipID)
        refreshSelectedTimelineRange()
        updateCurrentTime(clampedTimelineTime(currentTime))
        invalidateTimelineContent(
            .comparing(previous: previousTracks, current: project.tracks)
        )
        if graphSegment != nil {
            refreshGraphSegment()
        }
        updateHistoryFlags()
        persist()
        schedulePreviewRebuild(
            seekTo: clampedTimelineTime(currentTime),
            invalidation: command.invalidation
        )
    }

    func seek(to time: Double, exact: Bool = true) {
        playbackCommandGeneration &+= 1
        let clamped = clampedTimelineTime(time)
        updateCurrentTime(clamped)
        seekPlayer(to: clamped, exact: exact)
    }

    func seekPlayer(to time: Double, exact: Bool) {
        let clamped = clampedPlayableTime(time)
        let tolerance = exact ? CMTime.zero : CMTime(seconds: 0.035, preferredTimescale: 600)
        guard let player else { return }
        Task { [weak self, weak player] in
            guard let self, let player else { return }
            let didSeek = await self.boundedSeek(
                player: player,
                to: clamped,
                toleranceBefore: tolerance,
                toleranceAfter: tolerance,
                timeoutNanoseconds: 900_000_000
            )
            guard !didSeek, self.player === player else { return }
            self.schedulePreviewRecovery(
                reason: .seekTimeout,
                resumePlayback: self.isPlaying || self.pendingPlaybackResumeAfterPreviewRebuild
            )
        }
    }

    func beginScrub() {
        guard !isScrubbing else { return }
        playbackCommandGeneration &+= 1
        scrubSessionGeneration &+= 1
        wasPlayingBeforeScrub = isPlaying
        stopPlaybackWatchdog()
        player?.pause()
        isPlaying = false
        isScrubbing = true
        if rebuildTask != nil {
            deferredPreviewInvalidation.formUnion([
                .previewFrame,
                .compositionTopology,
                .audioMix,
            ])
            rebuildTask?.cancel()
            rebuildTask = nil
        }
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        pendingScrubSeekTime = nil
        isScrubSeekInFlight = false
        lastIssuedScrubSeekTime = nil
        lastScrubUIUpdate = 0
        scrubSeekLatencyEstimate = 0
        scrubSeekGeneration &+= 1
        previewQuality = .interactive
        renderService.livePreviewState.setInteractiveQualityOverride(true)
    }

    func endScrub(at time: Double) {
        let clamped = clampedTimelineTime(time)
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        pendingScrubSeekTime = nil
        isScrubSeekInFlight = false
        lastIssuedScrubSeekTime = nil
        lastScrubUIUpdate = 0
        scrubSessionGeneration &+= 1
        scrubSeekGeneration &+= 1
        let generation = scrubSessionGeneration
        player?.currentItem?.cancelPendingSeeks()
        updateCurrentTime(clamped)
        previewQuality = .balanced
        renderService.livePreviewState.setInteractiveQualityOverride(false)

        guard let player else {
            finishScrub(at: clamped, generation: generation)
            return
        }
        Task { [weak self, weak player] in
            guard let self, let player else { return }
            let didSeek = await self.boundedSeek(
                player: player,
                to: self.clampedPlayableTime(clamped),
                toleranceBefore: .zero,
                toleranceAfter: .zero,
                timeoutNanoseconds: 900_000_000
            )
            guard self.scrubSessionGeneration == generation else { return }
            self.finishScrub(at: clamped, generation: generation)
            if !didSeek, self.player === player {
                self.schedulePreviewRecovery(
                    reason: .seekTimeout,
                    resumePlayback: false
                )
            }
        }
    }

    private func finishScrub(at time: Double, generation: Int) {
        guard generation == scrubSessionGeneration, isScrubbing else { return }
        updateCurrentTime(time)
        isScrubbing = false
        wasPlayingBeforeScrub = false
        flushDeferredPreviewRebuild(
            seekTo: time,
            includeGeneratedLayerQualityRestore: true
        )
    }

    var navigationPoints: [Double] {
        cachedTimelineEvaluationIndex().navigationPoints(for: selectedTimelineItemID)
    }

    var canNavigateBackward: Bool {
        cachedTimelineEvaluationIndex().previousNavigationPoint(
            before: currentTime,
            tolerance: keyframeTimeTolerance,
            selectedItemID: selectedTimelineItemID
        ) != nil
    }

    var canNavigateForward: Bool {
        cachedTimelineEvaluationIndex().nextNavigationPoint(
            after: currentTime,
            tolerance: keyframeTimeTolerance,
            selectedItemID: selectedTimelineItemID
        ) != nil
    }

    func navigateBackward() {
        guard let target = cachedTimelineEvaluationIndex().previousNavigationPoint(
            before: currentTime,
            tolerance: keyframeTimeTolerance,
            selectedItemID: selectedTimelineItemID
        ) else { return }
        seek(to: target)
    }

    func navigateForward() {
        guard let target = cachedTimelineEvaluationIndex().nextNavigationPoint(
            after: currentTime,
            tolerance: keyframeTimeTolerance,
            selectedItemID: selectedTimelineItemID
        ) else { return }
        seek(to: target)
    }

    private func restoreSelectionIfPossible(_ clipID: UUID?) {
        if let clipID,
            let location = indexedTimelineItemLocation(id: clipID)
        {
            selectedClipID = clipID
            selectedTrackID = project.tracks[location.track].id
        } else {
            selectedClipID = nil
            selectedTrackID =
                project.tracks.first(where: { $0.kind == .visual })?.id
                ?? project.tracks.first?.id
            graphSegment = nil
        }
    }
}
