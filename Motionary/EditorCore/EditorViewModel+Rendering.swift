// Export, audio extraction, and preview composition rebuilding.

import AVFoundation
import CoreVideo
import SwiftUI

private enum PreviewFrameSynchronizationError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "The refreshed preview frame did not become available in time."
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
        let shouldResume = isPlaying
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
                invalidation: invalidation
            )
            guard !Task.isCancelled, generation == previewGeneration else { return }
            updatePreviewProgress(0.58, generation: generation)
            if let prepared {
                var itemAwaitingFreshFrame: AVPlayerItem?
                var outputAwaitingFreshFrame: AVPlayerItemVideoOutput?
                let shouldSynchronizeFreshFrame = !shouldResume && !isScrubbing
                defer {
                    if let outputAwaitingFreshFrame {
                        detachPreviewVideoOutput(ifMatching: outputAwaitingFreshFrame)
                    }
                }
                if prepared.topologyWasRebuilt || player == nil {
                    detachPreviewVideoOutput()
                    let item = AVPlayerItem(asset: prepared.composition)
                    item.videoComposition = prepared.videoComposition
                    item.audioMix = prepared.audioMix
                    if prepared.videoComposition != nil, shouldSynchronizeFreshFrame {
                        let output = installPreviewVideoOutput(on: item)
                        itemAwaitingFreshFrame = item
                        outputAwaitingFreshFrame = output
                    }
                    if player == nil {
                        player = AVPlayer(playerItem: item)
                        player?.volume = 1
                    } else {
                        player?.replaceCurrentItem(with: item)
                    }
                    installTimeObserver()
                    updatePreviewProgress(0.72, generation: generation)
                } else if let item = player?.currentItem {
                    if invalidation.contains(.previewFrame) {
                        detachPreviewVideoOutput()
                        item.videoComposition = prepared.videoComposition
                        if prepared.videoComposition != nil, shouldSynchronizeFreshFrame {
                            let output = installPreviewVideoOutput(on: item)
                            itemAwaitingFreshFrame = item
                            outputAwaitingFreshFrame = output
                        }
                    }
                    if invalidation.contains(.audioMix) {
                        item.audioMix = prepared.audioMix
                    }
                    updatePreviewProgress(0.72, generation: generation)
                }
                if !isScrubbing {
                    updateCurrentTime(seekTime)
                    await seekPlayerAndWait(to: seekTime)
                    updateCurrentTime(seekTime)
                }
                guard !Task.isCancelled, generation == previewGeneration else { return }
                updatePreviewProgress(0.86, generation: generation)
                if !shouldResume,
                    !isScrubbing,
                    let itemAwaitingFreshFrame,
                    let outputAwaitingFreshFrame
                {
                    try await waitForFreshPreviewFrame(
                        from: outputAwaitingFreshFrame,
                        on: itemAwaitingFreshFrame,
                        at: seekTime,
                        generation: generation
                    )
                }
                guard !Task.isCancelled, generation == previewGeneration else { return }
                updatePreviewProgress(0.96, generation: generation)
                liveTextPreviewID = nil
                previewContentRevision &+= 1
                previewState.status = .ready(generation: generation)
                previewProgress = 1
                refinePreviewQualityAfterFastFrameIfNeeded(
                    requestedQuality: requestedPreviewQuality,
                    seekTime: seekTime,
                    generation: generation
                )
                if shouldResume, !isScrubbing {
                    player?.play()
                    isPlaying = true
                }
            } else {
                player?.pause()
                detachPreviewVideoOutput()
                player = nil
                updateCurrentTime(seekTime)
                isPlaying = false
                liveTextPreviewID = nil
                previewState.status = .ready(generation: generation)
                previewProgress = 1
                refinePreviewQualityAfterFastFrameIfNeeded(
                    requestedQuality: requestedPreviewQuality,
                    seekTime: seekTime,
                    generation: generation
                )
            }
        } catch is CancellationError {
            if generation == previewGeneration {
                previewState.status = .cancelled
                previewProgress = 0
            }
        } catch {
            if !Task.isCancelled, generation == previewGeneration {
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

    func installInteractiveScrubPreviewCompositionIfNeeded() {
        guard project.containsGeneratedPreviewLayer else { return }
        let generation = scrubSeekGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await renderService.preparePreview(
                    for: project,
                    quality: .interactive,
                    invalidation: [.previewFrame]
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

    func restoreGeneratedLayerPreviewQualityAfterScrub(seekTo time: Double) {
        guard project.containsGeneratedPreviewLayer else { return }
        schedulePreviewRebuild(
            seekTo: time,
            delay: true,
            invalidation: [.previewFrame]
        )
    }

    private func seekPlayerAndWait(to time: Double) async {
        guard let player else { return }
        let clamped = clampedPlayableTime(time)
        await withCheckedContinuation { continuation in
            player.seek(
                to: CMTime(seconds: clamped, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                continuation.resume()
            }
        }
    }

    private func installPreviewVideoOutput(on item: AVPlayerItem) -> AVPlayerItemVideoOutput {
        let output = AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        item.add(output)
        previewVideoOutput = output
        return output
    }

    private func detachPreviewVideoOutput(
        ifMatching expectedOutput: AVPlayerItemVideoOutput? = nil
    ) {
        guard let previewVideoOutput else { return }
        if let expectedOutput, previewVideoOutput !== expectedOutput {
            return
        }
        player?.currentItem?.remove(previewVideoOutput)
        self.previewVideoOutput = nil
    }

    private func waitForFreshPreviewFrame(
        from output: AVPlayerItemVideoOutput,
        on item: AVPlayerItem,
        at time: Double,
        generation: Int
    ) async throws {
        let itemTime = CMTime(seconds: clampedPlayableTime(time), preferredTimescale: 600)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))

        while clock.now < deadline {
            try Task.checkCancellation()
            guard generation == previewGeneration,
                player?.currentItem === item,
                previewVideoOutput === output
            else {
                throw CancellationError()
            }

            if output.hasNewPixelBuffer(forItemTime: itemTime),
                output.pixelBufferAndDisplayTime(forItemTime: itemTime).pixelBuffer != nil
            {
                return
            }
            try await Task.sleep(for: .milliseconds(8))
        }

        throw PreviewFrameSynchronizationError.timedOut
    }
}

private extension EditorProject {
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
