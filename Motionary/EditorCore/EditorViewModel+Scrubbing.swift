// Scrubbing performance: coalesced seeks and deferred preview work.

import AVFoundation
import Foundation

extension EditorViewModel {
    func updateScrub(to time: Double) {
        let clamped = clampedTimelineTime(time)
        updateCurrentTime(clamped)
        guard isScrubbing else {
            seekPlayer(to: clamped, exact: true)
            return
        }

        pendingScrubSeekTime = clamped
        scheduleLatestScrubSeek()
    }

    func flushDeferredPreviewRebuild(seekTo time: Double) {
        guard !deferredPreviewInvalidation.isEmpty else { return }
        let invalidation = deferredPreviewInvalidation
        deferredPreviewInvalidation = []
        schedulePreviewRebuild(
            seekTo: time,
            delay: false,
            invalidation: invalidation
        )
    }

    private var scrubSeekInterval: CFTimeInterval {
        let framesPerSecond = min(max(Double(project.renderSettings.frameRate), 24), 60)
        return 1 / framesPerSecond
    }

    private func scheduleLatestScrubSeek() {
        let elapsed = CFAbsoluteTimeGetCurrent() - lastScrubUIUpdate
        if lastScrubUIUpdate == 0 || elapsed >= scrubSeekInterval {
            issueLatestScrubSeek()
            return
        }
        guard scrubSeekTask == nil else { return }

        let generation = scrubSessionGeneration
        let delay = max(scrubSeekInterval - elapsed, 0)
        scrubSeekTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                self.isScrubbing,
                self.scrubSessionGeneration == generation
            else { return }
            self.scrubSeekTask = nil
            self.issueLatestScrubSeek()
        }
    }

    private func issueLatestScrubSeek() {
        guard let target = pendingScrubSeekTime else { return }
        pendingScrubSeekTime = nil
        guard let player else { return }

        lastScrubUIUpdate = CFAbsoluteTimeGetCurrent()
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}
