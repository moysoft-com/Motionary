// Scrubbing performance: coalesced seeks and deferred preview work.

import AVFoundation
import Foundation

extension EditorViewModel {
    func updateScrub(to time: Double) {
        let clamped = min(max(time, 0), max(duration, 0))
        pendingScrubSeekTime = clamped
        processPendingScrubSeek()
        updateCurrentTime(clamped)
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

    private func processPendingScrubSeek() {
        guard !isScrubSeekInFlight else { return }
        guard let target = pendingScrubSeekTime else { return }
        pendingScrubSeekTime = nil
        guard let player else { return }

        isScrubSeekInFlight = true
        let tolerance = CMTime(seconds: 0.12, preferredTimescale: 600)
        
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isScrubSeekInFlight = false
                if self.pendingScrubSeekTime != nil {
                    self.processPendingScrubSeek()
                }
            }
        }
    }
}
