// Export, audio extraction, and preview composition rebuilding.

import AVFoundation
import SwiftUI

extension EditorViewModel {
    func exportProject(settings: VideoExportSettings) {
        exportTask = Task { [weak self] in
            guard let self else { return }
            guard !isExporting else { return }
            isExporting = true
            exportProgress = 0
            defer {
                isExporting = false
                exportTask = nil
            }
            do {
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
        let showBuildingUI =
            invalidation.contains(.compositionTopology) || player == nil
        if showBuildingUI {
            isRenderingPreview = true
            previewState.status = .building(generation: generation)
        }
        defer {
            if generation == previewGeneration, showBuildingUI {
                isRenderingPreview = false
            }
        }
        do {
            let prepared = try await renderService.preparePreview(
                for: project,
                quality: previewQuality,
                invalidation: invalidation
            )
            guard !Task.isCancelled, generation == previewGeneration else { return }
            if let prepared {
                if prepared.topologyWasRebuilt || player == nil {
                    let item = AVPlayerItem(asset: prepared.composition)
                    item.videoComposition = prepared.videoComposition
                    item.audioMix = prepared.audioMix
                    if player == nil {
                        player = AVPlayer(playerItem: item)
                        player?.volume = 1
                    } else {
                        player?.replaceCurrentItem(with: item)
                    }
                    installTimeObserver()
                } else if let item = player?.currentItem {
                    if invalidation.contains(.previewFrame) {
                        item.videoComposition = prepared.videoComposition
                    }
                    if invalidation.contains(.audioMix) {
                        item.audioMix = prepared.audioMix
                    }
                }
                if !isScrubbing {
                    updateCurrentTime(seekTime)
                    await seekPlayerAndWait(to: seekTime)
                }
                guard !Task.isCancelled, generation == previewGeneration else { return }
                liveTextPreviewID = nil
                previewContentRevision &+= 1
                previewState.status = .ready(generation: generation)
                if shouldResume, !isScrubbing {
                    player?.play()
                    isPlaying = true
                }
            } else {
                player?.pause()
                player = nil
                updateCurrentTime(0)
                isPlaying = false
                liveTextPreviewID = nil
                previewState.status = .ready(generation: generation)
            }
        } catch is CancellationError {
            if generation == previewGeneration {
                previewState.status = .cancelled
            }
        } catch {
            if !Task.isCancelled, generation == previewGeneration {
                let message = error.localizedDescription
                previewState.status = .failed(message)
                errorMessage = message
            }
        }
    }

    private func seekPlayerAndWait(to time: Double) async {
        guard let player else { return }
        let clamped = clampedTimelineTime(time)
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
}
