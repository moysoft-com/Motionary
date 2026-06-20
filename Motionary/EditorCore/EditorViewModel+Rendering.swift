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
                let asset = AVURLAsset(url: clip.source.url)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                guard !audioTracks.isEmpty else {
                    errorMessage = "This video does not contain an audio track."
                    return
                }

                mutateProject { project in
                    guard let location = project.clipLocation(id: selectedClipID) else { return }
                    let videoClip = project.tracks[location.track].clips[location.clip]
                    project.tracks[location.track].clips[location.clip].volume =
                        AnimatableProperty(baseValue: 0)

                    let audioSource = ClipSource(
                        url: videoClip.source.url,
                        mediaType: .audio,
                        originalDuration: videoClip.source.originalDuration,
                        naturalSize: nil
                    )
                    let audioClip = TimelineClip(
                        name: "\(videoClip.name) Audio",
                        source: audioSource,
                        timelineStart: videoClip.timelineStart,
                        sourceRange: videoClip.sourceRange,
                        volume: AnimatableProperty(
                            baseValue: max(videoClip.volume.baseValue, 1)
                        )
                    )
                    let audioTrackIndex = project.insertFreshTrack(kind: .audio)
                    project.tracks[audioTrackIndex].clips.append(audioClip)
                    project.tracks[audioTrackIndex].clips.sort { $0.timelineStart < $1.timelineStart }
                    self.selectedTrackID = project.tracks[audioTrackIndex].id
                    self.selectedClipID = audioClip.id
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func rebuildPreview(seekTo time: Double? = nil) async {
        let seekTime = min(max(time ?? currentTime, 0), max(duration, 0))
        let shouldResume = isPlaying
        isRenderingPreview = true
        defer {
            if !Task.isCancelled {
                isRenderingPreview = false
            }
        }
        do {
            let item = try await renderService.makePlayerItem(for: project)
            guard !Task.isCancelled else { return }
            if let item {
                if player == nil {
                    player = AVPlayer(playerItem: item)
                    player?.volume = 1
                } else {
                    player?.replaceCurrentItem(with: item)
                }
                installTimeObserver()
                seek(to: seekTime)
                if shouldResume {
                    player?.play()
                    isPlaying = true
                }
            } else {
                player?.pause()
                player = nil
                updateCurrentTime(0)
                isPlaying = false
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }
}
