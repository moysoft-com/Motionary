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
        previewQuality = .interactive
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
        livePreviewOverrideClearTask?.cancel()
        livePreviewOverrideClearTask = nil
        renderService.livePreviewState.removeAll()
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
        livePreviewFrameRefreshInFlight = false
        pendingLivePreviewFrameRefresh = false
        isRenderingPreview = false
        previewProgress = 0
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let previewVideoOutput, let item = player?.currentItem {
            item.remove(previewVideoOutput)
        }
        previewVideoOutput = nil
        player?.pause()
        player = nil
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
        }
    }

    func togglePlayback() {
        guard let player else { return }
        playbackCommandGeneration &+= 1
        let commandGeneration = playbackCommandGeneration

        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }

        let endTolerance = max(keyframeTimeTolerance, 0.05)
        if duration > 0, currentTime >= max(duration - endTolerance, 0) {
            player.pause()
            player.currentItem?.cancelPendingSeeks()
            updateCurrentTime(0)
            player.seek(
                to: .zero,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self, weak player] finished in
                guard finished, let player else { return }
                Task { @MainActor in
                    guard let self,
                        self.player === player,
                        self.playbackCommandGeneration == commandGeneration
                    else { return }
                    player.play()
                    self.isPlaying = true
                }
            }
            return
        }

        player.play()
        isPlaying = true
    }

    func toggleGraphPlayback() {
        guard let segment = graphSegment,
            let clip = project.clip(id: segment.clipID)
        else {
            togglePlayback()
            return
        }
        let start = clip.timelineStart + segment.startTime
        let end = clip.timelineStart + segment.endTime
        if !isPlaying, currentTime >= end - keyframeTimeTolerance {
            seek(to: start)
        }
        togglePlayback()
    }

    func undo() {
        guard let command = undoStack.popLast() else { return }
        let retainedClipID = selectedClipID
        command.undo(on: &project)
        redoStack.append(command)
        restoreSelectionIfPossible(retainedClipID)
        incrementTimelineContentRevision()
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
        guard let command = redoStack.popLast() else { return }
        let retainedClipID = selectedClipID
        command.apply(to: &project)
        undoStack.append(command)
        restoreSelectionIfPossible(retainedClipID)
        incrementTimelineContentRevision()
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
        player?.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    func beginScrub() {
        guard !isScrubbing else { return }
        playbackCommandGeneration &+= 1
        scrubSessionGeneration &+= 1
        wasPlayingBeforeScrub = isPlaying
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
        player.seek(
            to: CMTime(seconds: clampedPlayableTime(clamped), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                self?.finishScrub(at: clamped, generation: generation)
            }
        }
    }

    private func finishScrub(at time: Double, generation: Int) {
        guard generation == scrubSessionGeneration, isScrubbing else { return }
        updateCurrentTime(time)
        isScrubbing = false
        wasPlayingBeforeScrub = false
        flushDeferredPreviewRebuild(seekTo: time)
        restoreGeneratedLayerPreviewQualityAfterScrub(seekTo: time)
    }

    var navigationPoints: [Double] {
        let points: [Double]
        if let item = selectedTimelineItem {
            points =
                [item.timelineStart, item.timelineEnd]
                + item.allKeyframeTimes.map { item.timelineStart + $0 }
                + project.beatSnapAnchors()
        } else {
            points = project.tracks.flatMap(\.items).flatMap {
                [$0.timelineStart, $0.timelineEnd]
            }
            + project.beatSnapAnchors()
        }
        return points.map(clampedTimelineTime).sorted().reduce(into: [Double]()) { result, value in
            if result.last.map({ abs($0 - value) > keyframeTimeTolerance }) ?? true {
                result.append(value)
            }
        }
    }

    var canNavigateBackward: Bool {
        navigationPoints.contains { $0 < currentTime - keyframeTimeTolerance }
    }

    var canNavigateForward: Bool {
        navigationPoints.contains { $0 > currentTime + keyframeTimeTolerance }
    }

    func navigateBackward() {
        guard let target = navigationPoints.last(
            where: { $0 < currentTime - keyframeTimeTolerance }
        ) else { return }
        seek(to: target)
    }

    func navigateForward() {
        guard let target = navigationPoints.first(
            where: { $0 > currentTime + keyframeTimeTolerance }
        ) else { return }
        seek(to: target)
    }

    private func restoreSelectionIfPossible(_ clipID: UUID?) {
        if let clipID,
            let location = project.itemLocation(id: clipID)
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
