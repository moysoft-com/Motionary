// Editor lifecycle, playback, seeking, scrubbing, and undo history.

import AVFoundation

extension EditorViewModel {
    func suspendPreview() {
        guard !previewIsSuspended else { return }
        hapticPlayback.detach()
        previewIsSuspended = true
        if isPlaying, !isPreviewSeekInFlight, let player {
            let seconds = CMTimeGetSeconds(player.currentTime())
            if seconds.isFinite { updateCurrentTime(clampedPlayableTime(seconds)) }
        }
        pendingPlaybackResumeAfterPreviewRebuild = false
        previewGeneration &+= 1
        previewRecoveryGeneration &+= 1
        playbackCommandGeneration &+= 1
        scrubSessionGeneration &+= 1
        rebuildTask?.cancel()
        rebuildTask = nil
        previewRecoveryTask?.cancel()
        previewRecoveryTask = nil
        previewAudioRefreshTask?.cancel()
        previewAudioRefreshTask = nil
        cancelInteractivePreviewRebuild()
        replacePreviewPlayer(with: nil)
        renderService.livePreviewState.setInteractiveQualityOverride(false)
        isPlaying = false
        isScrubbing = false
        scrubIsFinishing = false
        wasPlayingBeforeScrub = false
        previewState.status = .cancelled
        previewProgress = 0
        clearDepthPreparationProgress()
    }

    func resumePreview() {
        guard previewIsSuspended else { return }
        previewIsSuspended = false
        if previewRecoveryCircuitIsOpen { errorMessage = nil }
        resetPreviewRecoveryCircuit()
        previewQuality = .balanced
        rotatePreviewRenderSession()
        let invalidation = deferredPreviewInvalidation.union([.previewFrame, .compositionTopology, .audioMix])
        deferredPreviewInvalidation = []
        schedulePreviewRebuild(seekTo: currentTime, delay: false, invalidation: invalidation)
    }

    func start() {
        previewIsSuspended = false
        hasRenderedInitialPreviewFrame = false
        installEffectRenderDiagnosticsHandler()
        EditorAudioSession.configurePlayback()
        TimelineCacheLifecycle.installMemoryWarningHandler()
        if project.tracks.contains(where: { !$0.isMuted && !$0.items.isEmpty && $0.kind != .audio && $0.kind != .haptic }) {
            Task.detached(priority: .userInitiated) {
                try? MetalRenderResources.validateAvailability()
            }
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
    }

    func stop() {
        previewIsSuspended = true
        hapticPlayback.detach()
        workspaceScrollOwners.removeAll()
        workspacePersistencePending = false
        playbackState.isStartingPlayback = false
        scratchAudio.shutdown()
        removeEffectRenderDiagnosticsHandler()
        let content = ProjectContent(editorProject: project)
        autosaveTask?.cancel()
        projectPosterTask?.cancel()
        projectPosterTask = nil
        clearDepthPreparationProgress()
        interactivePreviewThrottleTask?.cancel()
        interactivePreviewThrottleTask = nil
        livePreviewFrameRefreshTask?.cancel()
        livePreviewFrameRefreshTask = nil
        livePreviewSeekTask?.cancel()
        livePreviewSeekTask = nil
        liveAudioPreviewTask?.cancel()
        liveAudioPreviewTask = nil
        pendingLiveAudioPreviewItemID = nil
        liveAudioPreviewTaskGeneration &+= 1
        renderService.livePreviewState.removeAll()
        pendingLiveVisualOverrideItemIDs.removeAll(keepingCapacity: true)
        autosaveTask = Task { [projectStore, projectID] in
            do {
                try await projectStore.repository.save(content, projectID: projectID)
                projectStore.recordSavedContent(content, projectID: projectID)
                projectStore.schedulePosterRender(for: content.editorProject, projectID: projectID)
            } catch {
                AppLogger.persistence.warning(
                    "Failed to save project on close: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        rebuildTask?.cancel()
        rebuildTask = nil
        previewRecoveryTask?.cancel()
        previewRecoveryTask = nil
        previewAudioRefreshTask?.cancel()
        previewAudioRefreshTask = nil
        stopPlaybackWatchdog()
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        importTask?.cancel()
        importTask = nil
        exportTask?.cancel()
        exportTask = nil
        smoothMotionJobID = nil
        analysisTask?.cancel()
        analysisTask = nil
        analysisState = nil
        isImporting = false
        isExporting = false
        pendingScrubSeekTime = nil
        isScrubSeekInFlight = false
        lastIssuedScrubSeekTime = nil
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
        isScrubbing = false
        scrubIsFinishing = false
        isPlaying = false
    }

    func clearDepthPreparationProgress() {
        depthPreparationID = nil
        depthPreparationEffectID = nil
        depthPreparationProgress = nil
        depthPreparationIndeterminate = false
    }

    func handleDepthPreparationProgress(_ notification: Notification) {
        guard notification.userInfo?["ownerID"] as? UUID == depthProgressOwnerID,
              let id = notification.userInfo?["id"] as? UUID else { return }
        let progress = notification.userInfo?["progress"] as? Double
        if cancelledDepthPreparationID == id {
            if progress == nil { cancelledDepthPreparationID = nil }
            return
        }
        guard let progress else {
            if depthPreparationID == id { clearDepthPreparationProgress() }
            return
        }
        guard (isRenderingPreview || isExporting), !previewIsSuspended,
              let effectID = notification.userInfo?["effectID"] as? UUID,
              project.tracks.contains(where: { track in
                  !track.isMuted && track.items.contains { item in
                      item.editableVisuals?.effectStack.effects.contains {
                          $0.id == effectID && $0.moduleID == .depthMap && $0.isEnabled
                      } == true
                  }
              }) else {
            if depthPreparationID == id { clearDepthPreparationProgress() }
            return
        }
        depthPreparationID = id
        depthPreparationEffectID = effectID
        depthPreparationIndeterminate = notification.userInfo?["indeterminate"] as? Bool ?? false
        depthPreparationProgress = progress
    }

    func cancelLongRunningTask() {
        if analysisState?.kind == .smoothMotion {
            smoothMotionJobID = nil
            analysisTask?.cancel()
            analysisTask = nil
            analysisState = nil
            return
        }
        if let effectID = depthPreparationEffectID, depthPreparationProgress != nil {
            cancelledDepthPreparationID = depthPreparationID
            depthPreparationID = nil
            depthPreparationEffectID = nil
            depthPreparationProgress = nil
            rebuildTask?.cancel()
            rebuildTask = nil
            exportTask?.cancel()
            exportTask = nil
            isExporting = false
            analysisTask?.cancel()
            analysisTask = nil
            analysisState = nil
            isRenderingPreview = false
            pendingPlaybackResumeAfterPreviewRebuild = false
            if let before = project.tracks.lazy.flatMap(\.items).first(where: {
                $0.visualEditingClip()?.effectStack.effects.contains(where: { $0.id == effectID }) == true
            }), var clip = before.visualEditingClip() {
                clip.effectStack.effects.removeAll { $0.id == effectID }
                let after = before.mergingVisualEditingClip(clip)
                if activeKeyframeTarget?.effectID == effectID {
                    activeKeyframeTarget = clip.availableKeyframeTargets.first
                    selectedKeyframeID = nil
                }
                perform(ReplaceClipCommand(before: before, after: after,
                    invalidation: [.previewFrame, .userInterface, .persistence, .timelineLayout]))
            } else {
                schedulePreviewRebuild(seekTo: currentTime, delay: false)
            }
            return
        }
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
        if isRenderingPreview || rebuildTask != nil {
            rebuildTask?.cancel()
            rebuildTask = nil
            isRenderingPreview = false
            depthPreparationProgress = nil
            previewProgress = 0
            pendingPlaybackResumeAfterPreviewRebuild = false
        }
    }

    func togglePlayback() {
        guard !previewIsSuspended else { return }
        if previewRecoveryCircuitIsOpen {
            pendingPlaybackResumeAfterPreviewRebuild = true
            schedulePreviewRebuild(
                seekTo: currentTime,
                delay: false,
                invalidation: [.previewFrame, .compositionTopology, .audioMix]
            )
            return
        }
        guard let player else {
            if rebuildTask != nil || duration > 0 {
                pendingPlaybackResumeAfterPreviewRebuild.toggle()
                playbackState.isStartingPlayback = pendingPlaybackResumeAfterPreviewRebuild
                if pendingPlaybackResumeAfterPreviewRebuild, rebuildTask == nil {
                    schedulePreviewRebuild(seekTo: currentTime, delay: false,
                                           invalidation: [.previewFrame, .compositionTopology, .audioMix])
                }
            }
            return
        }
        if pendingPlaybackResumeAfterPreviewRebuild {
            pendingPlaybackResumeAfterPreviewRebuild = false
            playbackState.isStartingPlayback = false
            isPlaying = false
            player.pause()
            return
        }
        if playbackState.isStartingPlayback || isPlaying {
            pausePlaybackForUserCommand(player)
            if pendingPreviewInvalidation.intersection([.compositionTopology, .audioMix]).isEmpty {
                scratchAudio.prepare(item: player.currentItem, duration: duration, at: currentTime)
                prerollPausedPreviewIfReady()
            }
            return
        }
        playbackState.playbackStartRequestRevision &+= 1
        scratchAudio.end()

        let restartingAtEnd = duration > 0 && currentTime >= lastPlayableTime
        let target = restartingAtEnd ? 0 : clampedPlayableTime(currentTime)
        if restartingAtEnd { updateCurrentTime(target) }
        let frameTime = canonicalPreviewFrameTime(target)
        let targetFrame = renderService.livePreviewState.cachedFrame(
            at: frameTime, sessionID: previewRenderSessionID
        )
        invalidateLivePreviewPresentation(preservingFrame: targetFrame != nil)
        if let targetFrame {
            livePreviewPresentation.setFrame(targetFrame, at: frameTime)
        }
        let takingOverScrub = isScrubbing || scrubIsFinishing
        let seekTime = playbackSeekTime(to: target, on: player)
        if takingOverScrub {
            scrubSessionGeneration &+= 1
            scrubSeekGeneration &+= 1
            previewSeekGeneration &+= 1
            player.currentItem?.cancelPendingSeeks()
            scrubSeekTask?.cancel()
            scrubSeekTask = nil
            pendingScrubSeekTime = nil
            isScrubSeekInFlight = false
            isPreviewSeekInFlight = false
            lastIssuedScrubSeekTime = nil
            isScrubbing = false
            scrubIsFinishing = false
            wasPlayingBeforeScrub = false
            setPreviewQualityForInteraction(false)
            flushDeferredPreviewRebuild(seekTo: target)
        }
        playbackCommandGeneration &+= 1

        // A delayed rebuild may contain the last committed edit. Playing the
        // retained graph after discarding it would present stale geometry or
        // timing until another edit happens to trigger a rebuild.
        if rebuildTask != nil || !pendingPreviewInvalidation.isEmpty {
            pendingPlaybackResumeAfterPreviewRebuild = true
            playbackState.isStartingPlayback = true
            if !isRenderingPreview {
                schedulePreviewRebuild(
                    seekTo: target,
                    delay: false,
                    invalidation: []
                )
            }
            return
        }

        startPreparedPlayback(player, seekTo: seekTime)
    }

    func playbackSeekTime(to time: Double, on player: AVPlayer) -> Double? {
        let target = livePreviewPresentationTime(clampedPlayableTime(time))
        let position = player.currentTime()
        if playbackNeedsSeekAfterMixUpdate || playbackNeedsSeekAfterNavigation
            || isScrubSeekInFlight || isPreviewSeekInFlight || !position.isNumeric
            || abs(position.seconds - target) > 0.5 / 600
        {
            return target
        }
        return nil
    }

    @discardableResult
    func startPreparedPlayback(_ player: AVPlayer, seekTo time: Double? = nil) -> Task<Void, Never> {
        let generation = playbackCommandGeneration
        playbackState.isStartingPlayback = true
        return Task { [weak self, weak player] in
            guard let self, let player, self.ownsPlaybackStart(for: player, generation: generation) else { return }
            defer {
                if self.playbackCommandGeneration == generation, self.player === player {
                    self.playbackState.isStartingPlayback = false
                }
            }
            await self.scratchAudio.finishBeforePlayback()
            guard self.ownsPlaybackStart(for: player, generation: generation) else { return }
            async let audioSession: Void = self.preparePlaybackAudio()
            let needsInitialPosition = player.currentItem?.videoComposition != nil && self.lastPreviewRenderedFrameAt == 0
            let target = time ?? (needsInitialPosition || self.playbackNeedsSeekAfterNavigation
                ? self.livePreviewPresentationTime(self.clampedPlayableTime(self.currentTime)) : nil)
            if let target {
                var result = await self.boundedSeek(
                    player: player, to: target, toleranceBefore: .zero,
                    toleranceAfter: .zero, timeoutNanoseconds: 5_000_000_000
                )
                guard self.ownsPlaybackStart(for: player, generation: generation) else { return }
                if result == .interrupted {
                    result = await self.boundedSeek(
                        player: player, to: target, toleranceBefore: .zero,
                        toleranceAfter: .zero, timeoutNanoseconds: 5_000_000_000
                    )
                    guard self.ownsPlaybackStart(for: player, generation: generation) else { return }
                }
                guard result == .completed else {
                    if result != .superseded {
                        self.schedulePreviewRecovery(
                            reason: result == .timedOut ? .seekTimeout : .compositorFailure,
                            resumePlayback: true
                        )
                    }
                    return
                }
                self.playbackNeedsSeekAfterMixUpdate = false
            }
            await audioSession
            guard self.ownsPlaybackStart(for: player, generation: generation) else { return }
            // A new display pipeline needs both its first image and enough
            // decoded media to advance past it. A paused, ready layer can
            // reuse its existing preroll.
            if needsInitialPosition || (target != nil && !self.livePreviewPresentation.playerLayer.isReadyForDisplay) {
                self.primePreviewIfNeeded(player)
            }
            if let warmup = self.previewPrerollTask { await warmup.value }
            guard self.ownsPlaybackStart(for: player, generation: generation) else { return }
            self.previewPrerollTask = nil
            let hapticItems = self.project.audibleHapticItems
            let duration = self.duration
            self.hapticPlayback.detach()
            if HapticPlayback.isSupported, !hapticItems.isEmpty {
                let prepared = Task.detached(priority: .userInitiated) {
                    try HapticTrack.render(hapticItems, through: duration)
                }
                let track = await withTaskCancellationHandler {
                    try? await prepared.value
                } onCancel: {
                    prepared.cancel()
                }
                guard self.ownsPlaybackStart(for: player, generation: generation) else { return }
                if let track { self.hapticPlayback.attach(to: player, track: track) }
            }
            self.playbackNeedsSeekAfterNavigation = false
            self.isPlaying = true
            player.play()
            self.startPlaybackWatchdog()
        }
    }

    private func ownsPlaybackStart(for player: AVPlayer, generation: Int) -> Bool {
        !Task.isCancelled && self.player === player && playbackCommandGeneration == generation
            && playbackState.isStartingPlayback && !isScrubbing && !previewIsSuspended
    }

    func pausePlaybackForEditing() {
        hapticPlayback.stopAudition()
        guard isPlaying || playbackState.isStartingPlayback || pendingPlaybackResumeAfterPreviewRebuild else { return }
        pendingPlaybackResumeAfterPreviewRebuild = false
        guard let player else {
            playbackCommandGeneration &+= 1
            playbackState.isStartingPlayback = false
            isPlaying = false
            stopPlaybackWatchdog()
            return
        }
        pausePlaybackForUserCommand(player)
    }

    private func pausePlaybackForUserCommand(_ player: AVPlayer) {
        hapticPlayback.detach()
        let wasSeeking = isPreviewSeekInFlight
        previewSeekGeneration &+= 1
        isPreviewSeekInFlight = false
        playbackState.isStartingPlayback = false
        playbackCommandGeneration &+= 1
        scrubSessionGeneration &+= 1
        scrubSeekGeneration &+= 1

        stopPlaybackWatchdog()
        cancelPreviewPreroll()
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        // Capture the paused clock before the timeline hands control back to
        // its model. Its periodic sample can be a frame or two behind.
        if !wasSeeking, player.currentItem != nil {
            let seconds = CMTimeGetSeconds(player.currentTime())
            if seconds.isFinite { updateCurrentTime(clampedPlayableTime(seconds)) }
        }
        isPlaying = false
        isScrubbing = false
        wasPlayingBeforeScrub = false

        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        pendingScrubSeekTime = nil
        isScrubSeekInFlight = false
        lastIssuedScrubSeekTime = nil
        lastScrubUIUpdate = 0
        cancelInteractivePreviewRebuild()

        if rebuildTask != nil {
            deferredPreviewInvalidation.formUnion([
                .previewFrame,
                .compositionTopology,
                .audioMix,
            ])
            rebuildTask?.cancel()
            rebuildTask = nil
            previewGeneration &+= 1
            isRenderingPreview = false
            previewState.status = .cancelled
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
        let startedAt = CFAbsoluteTimeGetCurrent()
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
                    if self.isPreviewSeekInFlight {
                        lastProgressAt = ContinuousClock.now
                        lastObservedTime = nil
                        return true
                    }
                    let seconds = CMTimeGetSeconds(player.currentTime())
                    guard seconds.isFinite else {
                        self.schedulePreviewRecovery(
                            reason: .playbackStalled,
                            resumePlayback: true
                        )
                        return false
                    }
                    if let item = player.currentItem, self.finishPreviewPlayback(for: item) {
                        return false
                    }
                    if player.currentItem?.videoComposition != nil,
                        seconds < self.lastPlayableTime,
                        CFAbsoluteTimeGetCurrent() - max(self.lastPreviewRenderedFrameAt, startedAt) > 3.5,
                        seconds > (self.lastPreviewRenderedTimelineTime ?? seconds - 1) + 0.3
                    {
                        self.schedulePreviewRecovery(reason: .compositorFailure, resumePlayback: true)
                        return false
                    }
                    if let lastObservedTime,
                        seconds > lastObservedTime + 0.015
                    {
                        self.updateCurrentTime(self.clampedPlayableTime(seconds))
                        lastProgressAt = ContinuousClock.now
                    } else if lastObservedTime == nil {
                        lastProgressAt = ContinuousClock.now
                    } else if lastProgressAt.duration(to: ContinuousClock.now) > .milliseconds(1400) {
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

    func toggleGraphPlayback() {
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
        pausePlaybackForEditing()
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
        let invalidation = command.invalidation.union(deferredPreviewInvalidation)
        deferredPreviewInvalidation = []
        schedulePreviewRebuild(
            seekTo: clampedTimelineTime(currentTime),
            delay: false,
            invalidation: invalidation
        )
    }

    func redo() {
        if interactiveEditSnapshot != nil {
            // A newly committed gesture intentionally invalidates the old redo
            // branch, matching ordinary editor history semantics.
            finishInteractiveEdit(rebuild: true, delayRebuild: false)
        }
        guard let command = redoStack.popLast() else { return }
        pausePlaybackForEditing()
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
        let invalidation = command.invalidation.union(deferredPreviewInvalidation)
        deferredPreviewInvalidation = []
        schedulePreviewRebuild(
            seekTo: clampedTimelineTime(currentTime),
            delay: false,
            invalidation: invalidation
        )
    }

    func seek(to time: Double, exact: Bool = true) {
        pausePlaybackForEditing()
        playbackState.isStartingPlayback = false
        scratchAudio.end()
        invalidateLivePreviewPresentation()
        playbackCommandGeneration &+= 1
        // Keep the authored end position available for appending clips and
        // editing boundary keyframes. Only decoder requests are frame-clamped.
        let clamped = clampedTimelineTime(time)
        if isScrubbing {
            scrubSessionGeneration &+= 1
            scrubSeekGeneration &+= 1
            scrubSeekTask?.cancel()
            scrubSeekTask = nil
            pendingScrubSeekTime = nil
            isScrubSeekInFlight = false
            lastIssuedScrubSeekTime = nil
            isScrubbing = false
            scrubIsFinishing = false
            wasPlayingBeforeScrub = false
            player?.currentItem?.seekingWaitsForVideoCompositionRendering = true
            setPreviewQualityForInteraction(false)
            flushDeferredPreviewRebuild(seekTo: clamped)
        }
        updateCurrentTime(clamped)
        playbackState.timelineNavigationRevision &+= 1
        if previewRecoveryCircuitIsOpen {
            schedulePreviewRebuild(seekTo: clamped, delay: false)
            return
        }
        seekPlayer(to: clamped, exact: exact)
        if isPlaying { startPlaybackWatchdog() }
    }

    func seekPlayer(to time: Double, exact: Bool) {
        playbackNeedsSeekAfterNavigation = true
        let clamped = clampedPlayableTime(time)
        let tolerance = exact ? 0 : 0.035
        let toleranceAfter = min(tolerance, lastPlayableTime - clamped)
        guard let player else { return }
        let generation = playbackCommandGeneration
        Task { [weak self, weak player] in
            guard let self, let player, self.player === player,
                generation == self.playbackCommandGeneration else { return }
            let didSeek = await self.boundedSeek(
                player: player,
                to: clamped,
                toleranceBefore: CMTime(seconds: tolerance, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: toleranceAfter, preferredTimescale: 600),
                timeoutNanoseconds: 5_000_000_000
            )
            guard self.player === player,
                generation == self.playbackCommandGeneration else { return }
            if didSeek == .completed {
                self.prerollPausedPreviewIfReady()
            } else if didSeek == .timedOut {
                self.schedulePreviewRecovery(
                    reason: .seekTimeout,
                    resumePlayback: self.isPlaying || self.pendingPlaybackResumeAfterPreviewRebuild
                )
            }
        }
    }

    func beginScrub() {
        guard !previewIsSuspended else { return }
        guard !isScrubbing || scrubIsFinishing else { return }
        hapticPlayback.detach()
        if scrubIsFinishing { player?.currentItem?.cancelPendingSeeks() }
        let frameTime = currentScrubPresentationTime()
        let heldFrame = renderService.livePreviewState.cachedFrameNear(
            at: frameTime, sessionID: previewRenderSessionID,
            window: 1 / Double(max(project.renderSettings.frameRate, 1)))
        scrubIsFinishing = false
        playbackState.isStartingPlayback = false
        pendingPlaybackResumeAfterPreviewRebuild = false
        invalidateLivePreviewPresentation(preservingFrame: true)
        if let heldFrame {
            livePreviewPresentation.setFrame(heldFrame.frame, at: heldFrame.time)
        }
        playbackCommandGeneration &+= 1
        scrubSessionGeneration &+= 1
        wasPlayingBeforeScrub = isPlaying
        stopPlaybackWatchdog()
        cancelPreviewPreroll()
        player?.pause()
        isPlaying = false
        isScrubbing = true
        playbackNeedsSeekAfterNavigation = true
        player?.currentItem?.seekingWaitsForVideoCompositionRendering = true
        let hasPendingAudio = !pendingPreviewInvalidation.intersection([.audioMix, .compositionTopology]).isEmpty
        if hasPendingAudio {
            // The current gesture can continue as soon as the updated audio arrives.
            if rebuildTask == nil {
                schedulePreviewRebuild(seekTo: currentTime, delay: false, invalidation: [])
            }
        } else if rebuildTask != nil {
            deferredPreviewInvalidation.formUnion([
                .previewFrame,
                .compositionTopology,
                .audioMix,
            ])
            rebuildTask?.cancel()
            rebuildTask = nil
            previewGeneration &+= 1
            isRenderingPreview = false
            previewState.status = .cancelled
        }
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        pendingScrubSeekTime = nil
        isScrubSeekInFlight = false
        lastIssuedScrubSeekTime = nil
        lastScrubUIUpdate = 0
        scrubSeekGeneration &+= 1
        previewQuality = .interactive
        renderService.livePreviewState.setInteractiveQualityOverride(true)
        scratchAudio.begin(
            item: hasPendingAudio ? nil : player?.currentItem,
            duration: duration, at: currentTime
        )
    }

    func endScrub(at time: Double) {
        guard isScrubbing else { return }
        scratchAudio.end()
        scrubIsFinishing = true
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
        // On release, completion must acknowledge the final rendered frame,
        // rather than just the decoder's new time.
        player?.currentItem?.seekingWaitsForVideoCompositionRendering = true
        previewQuality = .balanced
        renderService.livePreviewState.setInteractiveQualityOverride(false)

        if pendingPreviewInvalidation.contains(.compositionTopology) {
            if rebuildTask == nil {
                schedulePreviewRebuild(seekTo: clamped, delay: false, invalidation: [])
            }
            return
        }

        guard let player else {
            finishScrub(at: clamped, generation: generation)
            return
        }
        Task { [weak self, weak player] in
            guard let self, let player,
                self.player === player,
                self.scrubSessionGeneration == generation
            else { return }
            let target = self.livePreviewPresentationTime(self.clampedPlayableTime(clamped))
            var didSeek = await self.boundedSeek(
                player: player,
                to: target,
                toleranceBefore: .zero,
                toleranceAfter: .zero,
                timeoutNanoseconds: 5_000_000_000
            )
            if didSeek == .interrupted, self.scrubSessionGeneration == generation {
                // An AVFoundation request can be cancelled as a scrub seek
                // hands off to the exact frame. Keep the displayed sample.
                didSeek = await self.boundedSeek(
                    player: player, to: target,
                    toleranceBefore: .zero, toleranceAfter: .zero,
                    timeoutNanoseconds: 5_000_000_000
                )
            }
            guard self.scrubSessionGeneration == generation, didSeek != .superseded else { return }
            if didSeek == .completed {
                self.finishScrub(at: clamped, generation: generation)
            } else {
                self.schedulePreviewRecovery(
                    reason: didSeek == .timedOut ? .seekTimeout : .compositorFailure,
                    resumePlayback: false
                )
            }
        }
    }

    func finishScrub(at time: Double, generation: Int) {
        guard generation == scrubSessionGeneration, isScrubbing else { return }
        updateCurrentTime(time)
        isScrubbing = false
        // AVPlayer's seek completion can precede the layer displaying its
        // new image. Keep the final composed sample over the player while
        // paused, so this handoff cannot briefly expose an empty layer.
        let frameTime = currentScrubPresentationTime()
        let state = renderService.livePreviewState
        let frame = state.cachedFrame(at: frameTime, sessionID: previewRenderSessionID)
        let needsQualityRestore = frame == nil && state.cachedFrame(
            at: frameTime, sessionID: previewRenderSessionID, allowsScrubFrames: true
        ) != nil
        if let frame {
            livePreviewPresentation.setFrame(frame, at: frameTime)
        } else if !needsQualityRestore, let frame = state.cachedFrameNear(
            at: frameTime, sessionID: previewRenderSessionID,
            window: 1 / Double(max(project.renderSettings.frameRate, 1))) {
            livePreviewPresentation.setFrame(frame.frame, at: frame.time)
        }
        scrubIsFinishing = false
        wasPlayingBeforeScrub = false
        let deferred = flushDeferredPreviewRebuild(seekTo: time)
        if needsQualityRestore, deferred.isEmpty, player?.currentItem?.videoComposition != nil {
            // AVPlayer can complete a same-time seek with its existing scrub
            // image. Reuse the decoded source frame to restore effect quality.
            pendingLivePreviewFrameRefresh = true
            enqueueLivePreviewFrameRefresh()
        } else {
            prerollPausedPreviewIfReady()
        }
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
        nextNavigationTarget != nil
    }

    private var nextNavigationTarget: Double? {
        // The exclusive project end and the last playable frame share the
        // same timeline position. Avoid offering a second forward step there.
        guard livePreviewPresentationTime(currentTime) < livePreviewPresentationTime(lastPlayableTime) else { return nil }
        return cachedTimelineEvaluationIndex().nextNavigationPoint(
            after: currentTime,
            tolerance: keyframeTimeTolerance,
            selectedItemID: selectedTimelineItemID
        )
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
        guard let target = nextNavigationTarget else { return }
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
