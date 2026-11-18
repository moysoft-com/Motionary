// Export, audio extraction, and preview composition rebuilding.

import AVFoundation
import SwiftUI

enum PreviewRecoveryReason: String {
    case seekTimeout
    case playerItemFailed
    case playbackStalled
    case compositorFailure
}

enum PreviewSeekResult: Sendable {
    case completed
    case interrupted
    case timedOut
    case superseded
}

private final class BoundedPreviewContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PreviewSeekResult, Never>?
    private var result: PreviewSeekResult?
    private var timeout: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<PreviewSeekResult, Never>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func startTimeout(nanoseconds: UInt64) {
        let task = Task {
            do { try await Task.sleep(nanoseconds: nanoseconds) }
            catch { return }
            resume(.timedOut)
        }
        lock.lock()
        let completed = result != nil
        if !completed { timeout = task }
        lock.unlock()
        if completed { task.cancel() }
    }

    func resume(_ value: PreviewSeekResult) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = continuation
        self.continuation = nil
        let timeout = timeout
        self.timeout = nil
        lock.unlock()
        timeout?.cancel()
        continuation?.resume(returning: value)
    }
}

extension EditorViewModel {
    func saveExportSettings(_ settings: VideoExportSettings) {
        let settings = settings.normalized
        let frameRateChanged = project.renderSettings.frameRate != settings.frameRate
        guard project.exportSettings != settings || frameRateChanged else { return }

        publishProjectChange()
        project.exportSettings = settings
        project.renderSettings.frameRate = settings.frameRate
        project.updatedAt = Date()
        persist()

        if frameRateChanged {
            schedulePreviewRebuild(
                seekTo: currentTime,
                delay: false,
                invalidation: [.previewFrame]
            )
        }
    }

    func exportProject(
        settings: VideoExportSettings, saveToPhotos: Bool = true, includeHaptics: Bool = false,
        packageAsMotionaryVideo: Bool = false
    ) {
        saveExportSettings(settings)
        guard exportTask == nil, !isPerformingLongTask else { return }
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isExporting = false
                exportTask = nil
            }
            do {
                try await prepareBackgroundRemovalArtifactsForExport()
                try Task.checkCancellation()
                isExporting = true
                exportProgress = 0
                recoverableExportURL = nil
                let snapshot = project
                let url = try await exportService.export(
                    project: snapshot,
                    settings: settings
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.exportProgress = progress
                    }
                }
                defer {
                    if recoverableExportURL != url { try? FileManager.default.removeItem(at: url) }
                }
                try Task.checkCancellation()
                if includeHaptics || packageAsMotionaryVideo {
                    let items = includeHaptics ? snapshot.audibleHapticItems : []
                    let title = snapshot.title
                    let package = Task.detached(priority: .userInitiated) {
                        let asset = AVURLAsset(url: url)
                        let duration = try await asset.load(.duration).seconds
                        let track = try HapticTrack.render(items, through: duration)
                        let poster = try? await MotionaryVideoArchive.makePosterJPEG(from: asset)
                        try Task.checkCancellation()
                        return try MotionaryVideoArchive.write(movie: url, title: title, haptics: track, posterJPEG: poster)
                    }
                    let packagedURL = try await withTaskCancellationHandler {
                        try await package.value
                    } onCancel: {
                        package.cancel()
                    }
                    if Task.isCancelled {
                        try? FileManager.default.removeItem(at: packagedURL.deletingLastPathComponent())
                        return
                    }
                    exportedVideoURL = packagedURL
                    return
                }
                if !saveToPhotos {
                    exportedVideoURL = try PhotoLibraryExportService.preserveVideo(at: url)
                    return
                }
                do {
                    try await PhotoLibraryExportService.saveVideo(at: url)
                } catch {
                    // A Photos rejection must not destroy a completed render.
                    // If preservation fails, keep the original temporary file.
                    recoverableExportURL = (try? PhotoLibraryExportService.preserveVideo(at: url)) ?? url
                    errorMessage = "The video was exported, but could not be saved to Photos. \(error.localizedDescription) You can save or share the finished video below."
                    return
                }
                showConfirmation("Video saved to Photos")
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func showConfirmation(_ message: String) {
        toastTask?.cancel()
        withAnimation {
            confirmationMessage = message
        }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    self?.confirmationMessage = nil
                }
            }
        }
    }

    func extractAudioFromSelectedClip() {
        guard let selectedClipID,
            let clip = selectedClip,
            clip.mediaType == .video
        else { return }

        Task {
            do {
                let mediaURL = projectStore.resolvedMediaURL(
                    project.mediaURL(for: clip),
                    projectID: projectID
                )
                let asset = AVURLAsset(url: mediaURL)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                guard !audioTracks.isEmpty else {
                    errorMessage = "This video does not contain an audio track."
                    return
                }

                let beforeTracks = project.tracks
                let beforeMediaLibrary = project.mediaLibrary
                var draft = project
                let videoClip = clip
                let audioSource = ClipSource(
                    url: mediaURL,
                    mediaType: .audio,
                    originalDuration: project.originalDuration(for: videoClip),
                    naturalSize: nil
                )
                var audioClip = TimelineClip(
                    name: "\(videoClip.name) Audio",
                    source: audioSource,
                    timelineStart: videoClip.timelineStart,
                    sourceRange: videoClip.sourceRange,
                    volume: AnimatableProperty(
                        baseValue: max(videoClip.volume.baseValue, 1)
                    )
                )
                draft.registerClipMedia(&audioClip, source: audioSource)
                if let location = draft.clipLocation(id: selectedClipID) {
                    draft.tracks[location.track].replaceLegacyClip(
                        id: selectedClipID,
                        with: {
                            var clip = draft.tracks[location.track].clips[location.clip]
                            clip.volume = AnimatableProperty(baseValue: 0)
                            return clip
                        }()
                    )
                }
                let audioTrackIndex = draft.insertFreshTrack(kind: .audio)
                draft.tracks[audioTrackIndex].appendLegacyClip(audioClip)
                draft.synchronizeMediaLibrary()
                commit(
                    AnyEditorCommand(
                        ExtractAudioCommand(
                            beforeTracks: beforeTracks,
                            beforeMediaLibrary: beforeMediaLibrary,
                            afterTracks: draft.tracks,
                            afterMediaLibrary: draft.mediaLibrary,
                            invalidation: [.previewFrame, .compositionTopology, .audioMix, .timelineLayout, .userInterface, .persistence]
                        )
                    )
                )
                self.selectedTrackID = draft.tracks[audioTrackIndex].id
                self.selectedClipID = audioClip.id
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func rebuildPreview(
        seekTo time: Double? = nil,
        invalidation: EditorInvalidation,
        generation: Int,
        commandGeneration: Int? = nil
    ) async {
        let requestedCommandGeneration = commandGeneration ?? playbackCommandGeneration
        let requestedPreviewQuality = previewQuality
        let showBuildingUI =
            invalidation.contains(.compositionTopology) || player == nil
        let marksPreviewAsBuilding =
            showBuildingUI || invalidation.contains(.previewFrame)
        if marksPreviewAsBuilding {
            previewProgress = 0.04
            isRenderingPreview = true
            previewState.status = .building(generation: generation)
        }
        defer {
            if generation == previewGeneration, marksPreviewAsBuilding {
                playbackState.isStartingPlayback = false
                isRenderingPreview = false
                depthPreparationProgress = nil
            }
        }
        do {
            updatePreviewProgress(0.12, generation: generation)
            let prepared = try await renderService.preparePreview(
                for: project,
                quality: requestedPreviewQuality == .interactive ? .balanced : requestedPreviewQuality,
                invalidation: invalidation,
                renderSessionID: UUID(),
                displayPixelSize: previewDisplayPixelSize
            )
            guard !Task.isCancelled, generation == previewGeneration else { return }
            // A user may seek while the preview graph is being prepared. The
            // newer playhead position takes precedence over the edit's older
            // requested position, including after an AVPlayerItem replacement.
            var seekTime = clampedTimelineTime(
                requestedCommandGeneration == playbackCommandGeneration ? (time ?? currentTime) : currentTime
            )
            if isPlaying, prepared?.topologyWasRebuilt == true,
                !invalidation.contains(.compositionTopology),
                let playingTime = player?.currentTime(), playingTime.isNumeric
            {
                seekTime = clampedTimelineTime(playingTime.seconds)
            }
            updatePreviewProgress(0.58, generation: generation)
            if let prepared {
                if let instruction = prepared.videoComposition?.instructions.first
                    as? MotionaryVideoCompositionInstruction,
                    instruction.renderSessionID != previewRenderSessionID
                {
                    // Frames/failures from the previous composition can arrive
                    // after a new graph is installed on the same player item.
                    previewRenderSessionID = instruction.renderSessionID
                    lastPreviewRenderedFrameAt = 0
                    lastPreviewRenderedTimelineTime = nil
                }
                let updatesAudio = prepared.topologyWasRebuilt || invalidation.contains(.audioMix)
                let replacesPlayer = prepared.topologyWasRebuilt || player == nil
                let requiresPlayerSynchronization = replacesPlayer || invalidation.contains(.previewFrame)
                if requiresPlayerSynchronization {
                    player?.pause()
                    player?.currentItem?.cancelPendingSeeks()
                    if isPlaying || pendingPlaybackResumeAfterPreviewRebuild {
                        pendingPlaybackResumeAfterPreviewRebuild = true
                        isPlaying = false
                    }
                }
                if replacesPlayer {
                    let item = AVPlayerItem(asset: prepared.composition)
                    item.audioMix = prepared.audioMix
                    item.videoComposition = prepared.videoComposition
                    replacePreviewPlayer(with: item, preservingFrame: true)
                    installPreviewItemHealthObservers(for: item)
                    installTimeObserver()
                    updatePreviewProgress(0.72, generation: generation)
                } else if let item = player?.currentItem {
                    if invalidation.contains(.previewFrame) {
                        cancelPreviewPreroll()
                        item.videoComposition = prepared.videoComposition
                    }
                    if invalidation.contains(.audioMix) {
                        cancelPreviewPreroll()
                        item.audioMix = prepared.audioMix
                        // Updating a paused item's audio mix can reset its
                        // audio clock after the last position was sampled.
                        if !isPlaying { playbackNeedsSeekAfterMixUpdate = true }
                    }
                    updatePreviewProgress(0.72, generation: generation)
                }
                // Replacing AVPlayerItem.audioMix is a live operation. Seeking
                // for an audio-only change interrupts playback and performs
                // unnecessary video decode/compositing work.
                if requiresPlayerSynchronization {
                    clearPendingLiveVisualOverrides()
                }
                if updatesAudio, !isPlaying, !pendingPlaybackResumeAfterPreviewRebuild {
                    scratchAudio.prepare(item: player?.currentItem, duration: prepared.duration, at: seekTime)
                }
                var synchronizedFrame = false
                if !isScrubbing, !isPlaying, !pendingPlaybackResumeAfterPreviewRebuild,
                    requiresPlayerSynchronization || playbackNeedsSeekAfterMixUpdate
                {
                    updateCurrentTime(seekTime)
                    let seekCommandGeneration = playbackCommandGeneration
                    let didSeek = await seekPlayerAndWait(to: seekTime, frameAligned: true)
                    guard !Task.isCancelled, generation == previewGeneration else { return }
                    if seekCommandGeneration == playbackCommandGeneration {
                        if didSeek != .completed {
                            if didSeek == .timedOut {
                                schedulePreviewRecovery(
                                    reason: .seekTimeout,
                                    resumePlayback: isPlaying || pendingPlaybackResumeAfterPreviewRebuild
                                )
                                return
                            }
                        } else {
                            playbackNeedsSeekAfterMixUpdate = false
                            synchronizedFrame = requiresPlayerSynchronization
                            updateCurrentTime(seekTime)
                        }
                    }
                }
                guard !Task.isCancelled, generation == previewGeneration else { return }
                updatePreviewProgress(0.86, generation: generation)
                updatePreviewProgress(0.96, generation: generation)
                previewContentRevision &+= 1
                previewState.status = .ready(generation: generation)
                pendingPreviewInvalidation.subtract(invalidation)
                previewProgress = 1
                resetPreviewRecoveryAttempts()
                if synchronizedFrame, !isPlaying, !pendingPlaybackResumeAfterPreviewRebuild {
                    // A completed seek does not mean AVPlayerLayer has
                    // displayed the new item yet. Keep the prior image until
                    // the canonical frame can replace it on our surface.
                    let target = canonicalPreviewFrameTime(seekTime)
                    if let frame = renderService.livePreviewState.cachedFrame(
                        at: target, sessionID: previewRenderSessionID)
                    {
                        livePreviewPresentation.setFrame(frame, at: target)
                        hasRenderedInitialPreviewFrame = true
                    } else {
                        // A same-time seek can complete from AVPlayer's old
                        // cache without invoking the new compositor. Keep
                        // the held image, but explicitly request the new
                        // revision instead of leaving it visible indefinitely.
                        pendingLivePreviewFrameRefresh = true
                    }
                }
                if !isPlaying, !pendingPlaybackResumeAfterPreviewRebuild,
                    pendingLivePreviewFrameRefresh || (requiresPlayerSynchronization && !synchronizedFrame)
                {
                    scheduleLivePreviewFrameRefresh()
                }
                if isScrubbing, requiresPlayerSynchronization {
                    if scrubIsFinishing {
                        endScrub(at: currentTime)
                    } else {
                        updateScrubPreview()
                    }
                }
                if requestedPreviewQuality == .interactive, !isScrubbing,
                    !renderService.livePreviewState.hasActiveOverrides
                {
                    setPreviewQualityForInteraction(false)
                }
                if !isScrubbing, pendingPlaybackResumeAfterPreviewRebuild, let player {
                    let time = requestedCommandGeneration == playbackCommandGeneration ? seekTime : currentTime
                    pendingPlaybackResumeAfterPreviewRebuild = false
                    updateCurrentTime(time)
                    await startPreparedPlayback(player, seekTo: playbackSeekTime(to: time, on: player)).value
                } else {
                    prerollPausedPreviewIfReady()
                }
            } else {
                replacePreviewPlayer(with: nil)
                updateCurrentTime(seekTime)
                isPlaying = false
                pendingPlaybackResumeAfterPreviewRebuild = false
                previewState.status = .ready(generation: generation)
                pendingPreviewInvalidation.subtract(invalidation)
                previewProgress = 1
                resetPreviewRecoveryAttempts()
                if !invalidation.intersection([.previewFrame, .compositionTopology]).isEmpty {
                    clearPendingLiveVisualOverrides()
                }
                if !isScrubbing { setPreviewQualityForInteraction(false) }
                if isScrubbing, scrubIsFinishing { endScrub(at: currentTime) }
            }
        } catch is CancellationError {
            if generation == previewGeneration {
                pendingPlaybackResumeAfterPreviewRebuild = false
                playbackState.isStartingPlayback = false
                previewState.status = .cancelled
                previewProgress = 0
            }
        } catch {
            if !Task.isCancelled, generation == previewGeneration {
                pendingPlaybackResumeAfterPreviewRebuild = false
                playbackState.isStartingPlayback = false
                let message = error.localizedDescription
                previewState.status = .failed(message)
                previewProgress = 0
                errorMessage = message
                if scrubIsFinishing {
                    finishScrub(at: currentTime, generation: scrubSessionGeneration)
                }
            }
        }
    }

    private func updatePreviewProgress(_ progress: Double, generation: Int) {
        guard generation == previewGeneration else { return }
        previewProgress = max(previewProgress, progress)
    }

    func replacePreviewPlayer(with item: AVPlayerItem?, preservingFrame: Bool = false) {
        hapticPlayback.detach()
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        scrubSeekGeneration &+= 1
        isScrubSeekInFlight = false
        pendingScrubSeekTime = nil
        lastIssuedScrubSeekTime = nil
        playbackNeedsSeekAfterMixUpdate = false
        livePreviewSeekTask?.cancel()
        livePreviewSeekTask = nil
        playbackState.isStartingPlayback = item != nil && pendingPlaybackResumeAfterPreviewRebuild
        if item == nil {
            if isScrubbing && !previewIsSuspended {
                scratchAudio.invalidate()
            } else {
                scratchAudio.shutdown()
            }
        }
        if !preservingFrame || item == nil { livePreviewPresentation.frame = nil }
        renderService.livePreviewState.clearPausedFrameRenderer()
        renderService.livePreviewState.invalidateComposedFrames()
        previewSeekGeneration &+= 1
        isPreviewSeekInFlight = false
        livePreviewFrameRefreshGeneration &+= 1
        livePreviewFrameRefreshInFlight = false
        stopPlaybackWatchdog()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        removePreviewItemHealthObservers()
        cancelPreviewPreroll()
        player?.pause()
        player?.currentItem?.cancelPendingSeeks()
        livePreviewPresentation.playerLayer.player = nil
        player?.replaceCurrentItem(with: nil)
        guard let item else {
            player = nil
            return
        }
        lastPreviewRenderedFrameAt = 0
        lastPreviewRenderedTimelineTime = nil
        item.seekingWaitsForVideoCompositionRendering = true
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.volume = 1
        livePreviewPresentation.playerLayer.player = newPlayer
        player = newPlayer
    }

    func rotatePreviewRenderSession() {
        previewRenderSessionID = UUID()
        lastPreviewRenderedFrameAt = 0
        lastPreviewRenderedTimelineTime = nil
        renderService.invalidatePreviewGraph()
    }

    func installPreviewItemHealthObservers(for item: AVPlayerItem) {
        removePreviewItemHealthObservers()
        playerItemGeneration &+= 1
        let generation = playerItemGeneration
        previewItemStatusObservation = item.observe(
            \.status,
            options: [.new]
        ) { [weak self, weak item] observedItem, _ in
            Task { @MainActor in
                guard let self,
                    let item,
                    observedItem === item,
                    self.player?.currentItem === item,
                    self.playerItemGeneration == generation
                else { return }
                if observedItem.status == .failed {
                    self.confirmPreviewItemFailure(
                        item,
                        generation: generation
                    )
                }
            }
        }

        let failed = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self,
                    let item,
                    self.player?.currentItem === item,
                    self.playerItemGeneration == generation
                else { return }
                self.confirmPreviewItemFailure(
                    item,
                    generation: generation
                )
            }
        }
        let stalled = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self,
                    let item,
                    self.player?.currentItem === item,
                    self.playerItemGeneration == generation,
                    self.isPlaying, !self.isPreviewSeekInFlight
                else { return }
                self.schedulePreviewRecovery(
                    reason: .playbackStalled,
                    resumePlayback: self.isPlaying || self.pendingPlaybackResumeAfterPreviewRebuild
                )
            }
        }
        let ended = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.playerItemGeneration == generation else { return }
                self.finishPreviewPlayback(for: item, reachedItemEnd: true)
            }
        }
        previewPlaybackStatusObservation = player?.observe(\.timeControlStatus, options: [.new]) {
            [weak self, weak item] observedPlayer, change in
            guard change.newValue == .paused else { return }
            Task { @MainActor in
                guard let self, let item, self.player === observedPlayer,
                    self.playerItemGeneration == generation,
                    observedPlayer.timeControlStatus == .paused, self.isPlaying else { return }
                self.finishPreviewPlayback(for: item)
            }
        }
        let compositorFailure = NotificationCenter.default.addObserver(
            forName: .motionaryVideoCompositorPersistentFailure,
            object: nil,
            // Metal completion handlers must never wait for the main thread:
            // Core Animation can be waiting for that same GPU queue. The Task
            // below delivers UI updates asynchronously on the main actor.
            queue: nil
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                    self.player?.currentItem === item,
                    self.playerItemGeneration == generation,
                    !self.isScrubbing || self.scrubIsFinishing,
                    notification.userInfo?["renderSessionID"] as? UUID == self.previewRenderSessionID
                else { return }
                self.schedulePreviewRecovery(
                    reason: .compositorFailure,
                    resumePlayback: self.isPlaying || self.pendingPlaybackResumeAfterPreviewRebuild
                )
            }
        }
        let renderedFrame = NotificationCenter.default.addObserver(
            forName: .motionaryVideoCompositorRenderedFrame,
            object: nil,
            // Metal completion handlers must never wait for the main thread:
            // Core Animation can be waiting for that same GPU queue. The Task
            // below delivers UI updates asynchronously on the main actor.
            queue: nil
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                    self.playerItemGeneration == generation,
                    self.player?.currentItem === item,
                    notification.userInfo?["renderSessionID"] as? UUID == self.previewRenderSessionID
                else { return }
                self.lastPreviewRenderedFrameAt = CFAbsoluteTimeGetCurrent()
                if let time = notification.userInfo?["compositionTime"] as? Double, time.isFinite {
                    self.lastPreviewRenderedTimelineTime = max(self.lastPreviewRenderedTimelineTime ?? time, time)
                    // Look the frame up under the current edit revision. A
                    // GPU completion can reach Main after the graph changes.
                    if self.isScrubbing,
                        abs(time - (self.lastIssuedScrubSeekTime ?? self.currentScrubPresentationTime())) < 0.000_01,
                        let frame = self.renderService.livePreviewState.cachedFrame(
                            at: time, sessionID: self.previewRenderSessionID)
                    {
                        self.presentScrubFrame(frame, at: time)
                    } else if !self.hasRenderedInitialPreviewFrame, !self.isPlaying,
                        !self.playbackState.isStartingPlayback,
                        abs(time - self.canonicalPreviewFrameTime(self.currentTime))
                            <= 1 / Double(max(self.project.renderSettings.frameRate, 1)),
                        let frame = self.renderService.livePreviewState.cachedFrame(
                            at: time, sessionID: self.previewRenderSessionID)
                    {
                        self.livePreviewPresentation.setFrame(frame, at: time)
                        self.hasRenderedInitialPreviewFrame = true
                    }
                }
            }
        }
        previewItemNotificationObservers = [failed, stalled, ended, compositorFailure, renderedFrame]
    }

    func confirmPreviewItemFailure(
        _ item: AVPlayerItem,
        generation: Int
    ) {
        Task { [weak self, weak item] in
            try? await Task.sleep(for: .milliseconds(450))
            await MainActor.run {
                guard let self,
                    let item,
                    self.player?.currentItem === item,
                    self.playerItemGeneration == generation,
                    item.status == .failed
                else { return }
                if let error = item.error {
                    let nsError = error as NSError
                    AppLogger.rendering.error(
                        "Preview player item failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public) userInfo=\(String(describing: nsError.userInfo), privacy: .public)"
                    )
                }
                self.schedulePreviewRecovery(
                    reason: .playerItemFailed,
                    resumePlayback: self.isPlaying || self.pendingPlaybackResumeAfterPreviewRebuild
                )
            }
        }
    }

    func removePreviewItemHealthObservers() {
        previewItemStatusObservation?.invalidate()
        previewItemStatusObservation = nil
        previewPlaybackStatusObservation?.invalidate()
        previewPlaybackStatusObservation = nil
        for observer in previewItemNotificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        previewItemNotificationObservers.removeAll()
        playerItemGeneration &+= 1
    }

    func resetPreviewRecoveryAttempts() {
        previewRecoveryAttemptCount = 0
        if !previewRecoveryCircuitIsOpen,
            CFAbsoluteTimeGetCurrent() - previewRecoveryLoopWindowStartedAt > 4
        {
            previewRecoveryLoopCount = 0
            previewRecoveryLoopWindowStartedAt = 0
        }
    }

    func resetPreviewRecoveryCircuit() {
        previewRecoveryCircuitIsOpen = false
        previewRecoveryLoopWindowStartedAt = 0
        previewRecoveryLoopCount = 0
        previewRecoveryAttemptCount = 0
    }

    func schedulePreviewRecovery(
        reason: PreviewRecoveryReason,
        resumePlayback: Bool
    ) {
        guard duration > 0, !previewIsSuspended, !previewRecoveryCircuitIsOpen,
            previewRecoveryTask == nil else { return }
        guard previewRecoveryAttemptCount < 3, registerPreviewRecoveryAttempt() else {
            openPreviewRecoveryCircuit(reason: reason)
            return
        }
        previewRecoveryGeneration &+= 1
        previewRecoveryAttemptCount &+= 1
        let generation = previewRecoveryGeneration
        let commandGeneration = playbackCommandGeneration
        previewRecoveryTask = Task { [weak self] in
            await MainActor.run {
                guard let self,
                    !Task.isCancelled, self.previewRecoveryGeneration == generation
                else { return }
                self.previewRecoveryTask = nil
                let shouldResume = self.playbackCommandGeneration == commandGeneration
                    ? resumePlayback : self.isPlaying || self.pendingPlaybackResumeAfterPreviewRebuild
                self.performHardPreviewRecovery(
                    reason: reason,
                    seekTo: self.clampedTimelineTime(self.currentTime),
                    resumePlayback: shouldResume,
                    generation: generation
                )
            }
        }
    }

    private func registerPreviewRecoveryAttempt() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if previewRecoveryLoopWindowStartedAt == 0
            || now - previewRecoveryLoopWindowStartedAt > 3
        {
            previewRecoveryLoopWindowStartedAt = now
            previewRecoveryLoopCount = 0
        }
        previewRecoveryLoopCount += 1
        return previewRecoveryLoopCount <= 3
    }

    private func openPreviewRecoveryCircuit(reason: PreviewRecoveryReason) {
        AppLogger.rendering.error(
            "Preview recovery circuit opened after repeated \(reason.rawValue, privacy: .public) failures"
        )
        previewRecoveryCircuitIsOpen = true
        previewRecoveryGeneration &+= 1
        playbackCommandGeneration &+= 1
        scrubSessionGeneration &+= 1
        scrubSeekGeneration &+= 1
        stopPlaybackWatchdog()
        previewRecoveryTask?.cancel()
        previewRecoveryTask = nil
        rebuildTask?.cancel()
        rebuildTask = nil
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        pendingScrubSeekTime = nil
        isScrubSeekInFlight = false
        lastIssuedScrubSeekTime = nil
        pendingPlaybackResumeAfterPreviewRebuild = false
        isPlaying = false
        isScrubbing = false
        scrubIsFinishing = false
        wasPlayingBeforeScrub = false
        replacePreviewPlayer(with: nil)
        renderService.livePreviewState.removeAll()
        pendingLiveVisualOverrideItemIDs.removeAll(keepingCapacity: true)
        previewProgress = 0
        previewState.status = .failed("Preview renderer was disabled after repeated \(reason.rawValue) failures.")
        errorMessage = "Preview renderer failed repeatedly. Press Play or change the timeline to retry preview."
    }

    private func performHardPreviewRecovery(
        reason: PreviewRecoveryReason,
        seekTo time: Double,
        resumePlayback: Bool,
        generation: Int
    ) {
        guard previewRecoveryGeneration == generation else { return }
        AppLogger.rendering.warning(
            "Recovering preview renderer after \(reason.rawValue, privacy: .public)"
        )
        playbackCommandGeneration &+= 1
        scrubSessionGeneration &+= 1
        scrubSeekGeneration &+= 1
        stopPlaybackWatchdog()
        pendingPlaybackResumeAfterPreviewRebuild = resumePlayback
        isPlaying = false
        isScrubbing = false
        scrubIsFinishing = false
        wasPlayingBeforeScrub = false
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        pendingScrubSeekTime = nil
        isScrubSeekInFlight = false
        lastIssuedScrubSeekTime = nil
        cancelInteractivePreviewRebuild()
        rebuildTask?.cancel()
        rebuildTask = nil
        replacePreviewPlayer(with: nil)
        renderService.livePreviewState.removeAll()
        pendingLiveVisualOverrideItemIDs.removeAll(keepingCapacity: true)
        previewQuality = .balanced
        rotatePreviewRenderSession()
        previewGeneration &+= 1
        let rebuildGeneration = previewGeneration
        let commandGeneration = playbackCommandGeneration
        previewState.status = .building(generation: rebuildGeneration)
        previewProgress = 0.04
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if rebuildGeneration == self.previewGeneration {
                    self.rebuildTask = nil
                }
            }
            await self.rebuildPreview(
                seekTo: time,
                invalidation: [.previewFrame, .compositionTopology, .audioMix],
                generation: rebuildGeneration,
                commandGeneration: commandGeneration
            )
        }
    }

    func cancelPreviewPreroll() {
        previewPrerollTask?.cancel()
        previewPrerollTask = nil
        player?.cancelPendingPrerolls()
    }

    /// Keep a ready or in-flight preroll for the next Play command. A seek,
    /// replacement or mix edit clears it before changing the player's inputs.
    func prerollPausedPreviewIfReady() {
        guard let player, !isPlaying, !isScrubbing, !isPreviewSeekInFlight,
            !playbackState.isStartingPlayback, !pendingPlaybackResumeAfterPreviewRebuild
        else { return }
        primePreviewIfNeeded(player)
    }

    func primePreviewIfNeeded(_ player: AVPlayer) {
        guard previewPrerollTask == nil, player.status == .readyToPlay else { return }
        previewPrerollTask = Task { @MainActor [weak self, weak player] in
            guard !Task.isCancelled, let player, self?.player === player,
                player.status == .readyToPlay, player.rate == 0 else { return }
            let request = BoundedPreviewContinuation()
            let result = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard request.install(continuation) else { return }
                    player.preroll(atRate: 1) { ready in
                        request.resume(ready ? .completed : .interrupted)
                    }
                    request.startTimeout(nanoseconds: 450_000_000)
                }
            } onCancel: { request.resume(.superseded) }
            if result == .timedOut, !Task.isCancelled { player.cancelPendingPrerolls() }
        }
    }

    @discardableResult
    func seekPlayerAndWait(to time: Double, frameAligned: Bool = false) async -> PreviewSeekResult {
        guard let player else { return .superseded }
        let presentationTime = frameAligned
            ? canonicalPreviewFrameTime(time)
            : livePreviewPresentationTime(clampedPlayableTime(time))
        player.currentItem?.cancelPendingSeeks()
        let succeeded = await boundedSeek(
            player: player,
            to: presentationTime,
            toleranceBefore: .zero,
            toleranceAfter: .zero,
            timeoutNanoseconds: 5_000_000_000,
            frameAligned: frameAligned
        )
        return succeeded
    }

    @discardableResult
    func boundedSeek(
        player: AVPlayer,
        to time: Double,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        timeoutNanoseconds: UInt64,
        frameAligned: Bool = false
    ) async -> PreviewSeekResult {
        previewSeekGeneration &+= 1
        let generation = previewSeekGeneration
        isPreviewSeekInFlight = true
        lastPreviewRenderedTimelineTime = nil
        cancelPreviewPreroll()
        let item = player.currentItem
        let boundedContinuation = BoundedPreviewContinuation()
        let result: PreviewSeekResult = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard boundedContinuation.install(continuation) else { return }
                guard !Task.isCancelled else {
                    boundedContinuation.resume(.superseded)
                    return
                }
                let timescale = frameAligned ? max(self.project.renderSettings.frameRate, 1) : 600
                player.seek(
                    to: CMTime(seconds: time, preferredTimescale: timescale),
                    toleranceBefore: toleranceBefore,
                    toleranceAfter: toleranceAfter
                ) { finished in
                    boundedContinuation.resume(finished ? .completed : .interrupted)
                }
                boundedContinuation.startTimeout(nanoseconds: timeoutNanoseconds)
            }
        } onCancel: { [weak self, weak player] in
            // Cancellation must wake the waiter immediately, even if
            // AVFoundation never calls back. Do not leave a five-second seek
            // alive after its gesture or composition generation was replaced.
            boundedContinuation.resume(.superseded)
            Task { @MainActor in
                guard let self, let player,
                    self.previewSeekGeneration == generation,
                    self.player === player, player.currentItem === item
                else { return }
                item?.cancelPendingSeeks()
            }
        }
        guard generation == previewSeekGeneration else { return .superseded }
        isPreviewSeekInFlight = false
        guard self.player === player,
            player.currentItem === item,
            !Task.isCancelled
        else { return .superseded }
        if result == .timedOut { item?.cancelPendingSeeks() }
        return result
    }

}

extension EditorProject {
    var containsGeneratedPreviewLayer: Bool {
        containsGeneratedPreviewLayer(in: tracks)
    }

    func containsGeneratedPreviewLayer(in tracks: [TimelineTrack]) -> Bool {
        for track in tracks where !track.isMuted {
            for item in track.items {
                switch item {
                case .shape, .text:
                    return true
                case .compound(let compound):
                    if let sequence = sequences[compound.sequenceID],
                        containsGeneratedPreviewLayer(in: sequence.tracks)
                    {
                        return true
                    }
                case .media, .caption, .adjustment, .haptic:
                    continue
                }
            }
        }
        return false
    }
}
