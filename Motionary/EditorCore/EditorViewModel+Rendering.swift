// Export, audio extraction, and preview composition rebuilding.

import AVFoundation
import SwiftUI

enum PreviewRecoveryReason: String {
    case seekTimeout
    case playerItemFailed
    case playbackStalled
    case compositorFailure
}

private final class BoundedSeekContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

extension EditorViewModel {
    func exportProject(settings: VideoExportSettings) {
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
                let url = try await exportService.export(
                    project: project,
                    settings: settings
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.exportProgress = progress
                    }
                }
                defer { try? FileManager.default.removeItem(at: url) }
                try Task.checkCancellation()
                try await PhotoLibraryExportService.saveVideo(at: url)
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
        generation: Int
    ) async {
        let seekTime = clampedTimelineTime(time ?? currentTime)
        let shouldResume = isPlaying || pendingPlaybackResumeAfterPreviewRebuild
        let requestedPreviewQuality = previewQuality
        let showBuildingUI =
            invalidation.contains(.compositionTopology) || player == nil
        let marksPreviewAsBuilding =
            showBuildingUI || (!shouldResume && invalidation.contains(.previewFrame))
        if marksPreviewAsBuilding {
            previewProgress = 0.04
            isRenderingPreview = true
            previewState.status = .building(generation: generation)
        }
        defer {
            if generation == previewGeneration, marksPreviewAsBuilding {
                isRenderingPreview = false
            }
        }
        do {
            updatePreviewProgress(0.12, generation: generation)
            let prepared = try await renderService.preparePreview(
                for: project,
                quality: previewQuality,
                invalidation: invalidation,
                renderSessionID: previewRenderSessionID
            )
            guard !Task.isCancelled, generation == previewGeneration else { return }
            updatePreviewProgress(0.58, generation: generation)
            if let prepared {
                let requiresPlayerSynchronization =
                    prepared.topologyWasRebuilt || invalidation.contains(.previewFrame)
                if requiresPlayerSynchronization {
                    player?.pause()
                    player?.currentItem?.cancelPendingSeeks()
                    if shouldResume {
                        pendingPlaybackResumeAfterPreviewRebuild = true
                        isPlaying = false
                    }
                }
                if prepared.topologyWasRebuilt || player == nil {
                    let item = AVPlayerItem(asset: prepared.composition)
                    item.videoComposition = prepared.videoComposition
                    item.audioMix = prepared.audioMix
                    replacePreviewPlayer(with: item)
                    installPreviewItemHealthObservers(for: item)
                    installTimeObserver()
                    updatePreviewProgress(0.72, generation: generation)
                } else if let item = player?.currentItem {
                    if invalidation.contains(.previewFrame) {
                        item.videoComposition = prepared.videoComposition
                    }
                    if invalidation.contains(.audioMix) {
                        item.audioMix = prepared.audioMix
                    }
                    updatePreviewProgress(0.72, generation: generation)
                }
                // Replacing AVPlayerItem.audioMix is a live operation. Seeking
                // for an audio-only change interrupts playback and performs
                // unnecessary video decode/compositing work.
                if !isScrubbing, requiresPlayerSynchronization {
                    updateCurrentTime(seekTime)
                    let didSeek = await seekPlayerAndWait(to: seekTime)
                    if !didSeek {
                        schedulePreviewRecovery(
                            reason: .seekTimeout,
                            resumePlayback: shouldResume
                        )
                        return
                    }
                    updateCurrentTime(seekTime)
                }
                guard !Task.isCancelled, generation == previewGeneration else { return }
                updatePreviewProgress(0.86, generation: generation)
                updatePreviewProgress(0.96, generation: generation)
                previewContentRevision &+= 1
                previewState.status = .ready(generation: generation)
                previewProgress = 1
                resetPreviewRecoveryAttempts()
                if !invalidation.intersection([.previewFrame, .compositionTopology]).isEmpty {
                    clearPendingLiveVisualOverrides()
                }
                refinePreviewQualityAfterFastFrameIfNeeded(
                    requestedQuality: requestedPreviewQuality,
                    seekTime: seekTime,
                    generation: generation
                )
                if shouldResume, !isScrubbing {
                    player?.play()
                    isPlaying = true
                    startPlaybackWatchdog()
                    pendingPlaybackResumeAfterPreviewRebuild = false
                }
            } else {
                replacePreviewPlayer(with: nil)
                updateCurrentTime(seekTime)
                isPlaying = false
                pendingPlaybackResumeAfterPreviewRebuild = false
                previewState.status = .ready(generation: generation)
                previewProgress = 1
                resetPreviewRecoveryAttempts()
                if !invalidation.intersection([.previewFrame, .compositionTopology]).isEmpty {
                    clearPendingLiveVisualOverrides()
                }
                refinePreviewQualityAfterFastFrameIfNeeded(
                    requestedQuality: requestedPreviewQuality,
                    seekTime: seekTime,
                    generation: generation
                )
            }
        } catch is CancellationError {
            if generation == previewGeneration {
                pendingPlaybackResumeAfterPreviewRebuild = false
                previewState.status = .cancelled
                previewProgress = 0
            }
        } catch {
            if !Task.isCancelled, generation == previewGeneration {
                pendingPlaybackResumeAfterPreviewRebuild = false
                let message = error.localizedDescription
                previewState.status = .failed(message)
                previewProgress = 0
                errorMessage = message
            }
        }
    }

    private func updatePreviewProgress(_ progress: Double, generation: Int) {
        guard generation == previewGeneration else { return }
        previewProgress = max(previewProgress, progress)
    }

    private func refinePreviewQualityAfterFastFrameIfNeeded(
        requestedQuality: PreviewQuality,
        seekTime: Double,
        generation: Int
    ) {
        guard generation == previewGeneration,
            requestedQuality == .interactive,
            !isScrubbing,
            !isPlaying,
            !renderService.livePreviewState.hasActiveOverrides
        else { return }

        previewQuality = .balanced
        schedulePreviewRebuild(
            seekTo: seekTime,
            delay: true,
            invalidation: [.previewFrame]
        )
    }

    func replacePreviewPlayer(with item: AVPlayerItem?) {
        stopPlaybackWatchdog()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        removePreviewItemHealthObservers()
        player?.pause()
        player?.currentItem?.cancelPendingSeeks()
        player?.replaceCurrentItem(with: nil)
        guard let item else {
            player = nil
            previewRendererIdentity = UUID()
            return
        }
        lastPreviewRenderedFrameAt = 0
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.volume = 1
        player = newPlayer
        previewRendererIdentity = UUID()
    }

    func rotatePreviewRenderSession() {
        previewRenderSessionID = UUID()
        previewRendererIdentity = UUID()
        lastPreviewRenderedFrameAt = 0
        renderService.invalidatePreviewGraph()
    }

    func installInteractiveScrubPreviewCompositionIfNeeded() {
        guard project.containsGeneratedPreviewLayer else { return }
        let generation = scrubSeekGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await renderService.preparePreview(
                    for: project,
                    quality: .interactive,
                    invalidation: [.previewFrame],
                    renderSessionID: previewRenderSessionID
                )
                guard !Task.isCancelled,
                    self.isScrubbing,
                    self.scrubSeekGeneration == generation,
                    let prepared,
                    let item = self.player?.currentItem
                else { return }
                item.videoComposition = prepared.videoComposition
            } catch is CancellationError {
                return
            } catch {
                AppLogger.rendering.warning(
                    "Failed to install interactive scrub preview: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
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
                    self.playerItemGeneration == generation
                else { return }
                self.schedulePreviewRecovery(
                    reason: .playbackStalled,
                    resumePlayback: self.isPlaying || self.pendingPlaybackResumeAfterPreviewRebuild
                )
            }
        }
        let compositorFailure = NotificationCenter.default.addObserver(
            forName: .motionaryVideoCompositorPersistentFailure,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                    self.player?.currentItem === item,
                    self.playerItemGeneration == generation,
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
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                    self.playerItemGeneration == generation,
                    notification.userInfo?["renderSessionID"] is UUID
                else { return }
                self.lastPreviewRenderedFrameAt = CFAbsoluteTimeGetCurrent()
            }
        }
        previewItemNotificationObservers = [failed, stalled, compositorFailure, renderedFrame]
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
                guard self.lastPreviewRenderedFrameAt == 0 else {
                    return
                }
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
        guard duration > 0 else { return }
        guard !previewRecoveryCircuitIsOpen else { return }
        guard registerPreviewRecoveryAttempt(reason: reason) else {
            openPreviewRecoveryCircuit(reason: reason)
            return
        }
        previewRecoveryGeneration &+= 1
        previewRecoveryAttemptCount &+= 1
        let generation = previewRecoveryGeneration
        let targetTime = clampedTimelineTime(currentTime)
        let shouldResume = resumePlayback
        previewRecoveryTask?.cancel()
        previewRecoveryTask = Task { [weak self] in
            await MainActor.run {
                guard let self,
                    self.previewRecoveryGeneration == generation
                else { return }
                self.performHardPreviewRecovery(
                    reason: reason,
                    seekTo: targetTime,
                    resumePlayback: shouldResume,
                    generation: generation
                )
            }
        }
    }

    private func registerPreviewRecoveryAttempt(reason: PreviewRecoveryReason) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if previewRecoveryLoopWindowStartedAt == 0
            || now - previewRecoveryLoopWindowStartedAt > 3
        {
            previewRecoveryLoopWindowStartedAt = now
            previewRecoveryLoopCount = 0
        }
        previewRecoveryLoopCount += 1
        if previewRecoveryLoopCount <= 3 {
            return true
        }
        AppLogger.rendering.error(
            "Preview recovery circuit opened after repeated \(reason.rawValue, privacy: .public) failures"
        )
        return false
    }

    private func openPreviewRecoveryCircuit(reason: PreviewRecoveryReason) {
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
        wasPlayingBeforeScrub = false
        replacePreviewPlayer(with: nil)
        renderService.livePreviewState.removeAll()
        pendingLiveVisualOverrideItemIDs.removeAll(keepingCapacity: true)
        previewProgress = 0
        previewState.status = .failed("Preview renderer was disabled after repeated \(reason.rawValue) failures.")
        errorMessage = "Preview renderer failed repeatedly. Editing stays available; change the timeline or reopen the project to retry preview."
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
        wasPlayingBeforeScrub = false
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        pendingScrubSeekTime = nil
        isScrubSeekInFlight = false
        lastIssuedScrubSeekTime = nil
        scrubSeekLatencyEstimate = 0
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
                generation: rebuildGeneration
            )
        }
    }

    @discardableResult
    func seekPlayerAndWait(to time: Double) async -> Bool {
        guard let player else { return true }
        let clamped = clampedPlayableTime(time)
        let frameDuration = 1 / Double(max(project.renderSettings.frameRate, 1))
        // Some compressed sources expose their first decoded sample at the
        // first frame boundary rather than exactly t=0. Requesting zero with a
        // custom compositor can therefore produce a valid but black frame.
        // Keep the editor playhead at zero while presenting the first actual
        // video sample.
        let presentationTime =
            clamped <= 0.000_001 && lastPlayableTime >= frameDuration
            ? frameDuration
            : clamped
        player.currentItem?.cancelPendingSeeks()
        let succeeded = await boundedSeek(
            player: player,
            to: presentationTime,
            toleranceBefore: .zero,
            toleranceAfter: .zero,
            timeoutNanoseconds: 900_000_000
        )
        return succeeded
    }

    @discardableResult
    func boundedSeek(
        player: AVPlayer,
        to time: Double,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let boundedContinuation = BoundedSeekContinuation(continuation)
            player.seek(
                to: CMTime(seconds: time, preferredTimescale: 600),
                toleranceBefore: toleranceBefore,
                toleranceAfter: toleranceAfter
            ) { finished in
                boundedContinuation.resume(finished)
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                boundedContinuation.resume(false)
            }
        }
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
                case .media, .caption, .adjustment:
                    continue
                }
            }
        }
        return false
    }
}
