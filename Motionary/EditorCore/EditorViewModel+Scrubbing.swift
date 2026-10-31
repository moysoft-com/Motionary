// Scrubbing performance: coalesced seeks and deferred preview work.

import AVFoundation
import Foundation
import os

extension EditorViewModel {
    func updateScrub(to time: Double) {
        guard !isPlaying, !playbackState.isStartingPlayback, !pendingPlaybackResumeAfterPreviewRebuild else { return }
        let clamped = clampedTimelineTime(time)
        updateCurrentTime(clamped)
        guard isScrubbing else {
            seekPlayer(to: clamped, exact: false)
            return
        }

        scratchAudio.update(to: clamped)
        let frameDuration = 1 / Double(max(project.renderSettings.frameRate, 1))
        let target = floor(clampedPlayableTime(clamped) / frameDuration + 0.000_001) * frameDuration
        pendingScrubSeekTime = CMTimeGetSeconds(CMTime(
            seconds: target, preferredTimescale: 600
        ))
        scheduleLatestScrubSeek()
    }

    /// Restores the canonical preview graph with one rebuild after scrubbing.
    /// Generated layers need a balanced-quality frame, but that request must
    /// be unioned with any deferred topology/audio work instead of cancelling
    /// it with a second descriptor-only task.
    @discardableResult
    func flushDeferredPreviewRebuild(
        seekTo time: Double,
        includeGeneratedLayerQualityRestore: Bool = false
    ) -> EditorInvalidation {
        let hadDeferredWork = !deferredPreviewInvalidation.isEmpty
        var invalidation = deferredPreviewInvalidation
        deferredPreviewInvalidation = []
        if includeGeneratedLayerQualityRestore,
            project.containsGeneratedPreviewLayer
        {
            invalidation.insert(.previewFrame)
        }
        guard !invalidation.isEmpty else { return [] }
        schedulePreviewRebuild(
            seekTo: time,
            delay: !hadDeferredWork,
            invalidation: invalidation
        )
        return invalidation
    }

    private func scheduleLatestScrubSeek() {
        guard let target = pendingScrubSeekTime else { return }
        // Repeated gesture samples within the same seek time need no decoder
        // work. A reversal to the in-flight target also replaces an older
        // pending destination instead of queuing a redundant seek.
        if target == lastIssuedScrubSeekTime {
            pendingScrubSeekTime = nil
            return
        }
        guard !isScrubSeekInFlight, scrubSeekTask == nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let minimumInterval = scrubSeekMinimumInterval()
        let elapsed = now - lastScrubUIUpdate
        guard elapsed < minimumInterval else {
            issueLatestScrubSeek()
            return
        }

        let delay = minimumInterval - elapsed
        scrubSeekTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            await MainActor.run {
                guard let self else { return }
                self.scrubSeekTask = nil
                self.issueLatestScrubSeek()
            }
        }
    }

    private func issueLatestScrubSeek() {
        guard let target = pendingScrubSeekTime else { return }
        guard let player else { return }
        pendingScrubSeekTime = nil
        isScrubSeekInFlight = true

        lastScrubUIUpdate = CFAbsoluteTimeGetCurrent()
        lastIssuedScrubSeekTime = target
        scrubSeekGeneration &+= 1
        let seekGeneration = scrubSeekGeneration
        let sessionGeneration = scrubSessionGeneration
        let issuedAt = CFAbsoluteTimeGetCurrent()
        let signpostID = OSSignpostID(log: TimelinePerformanceSignposts.log)
        os_signpost(
            .begin,
            log: TimelinePerformanceSignposts.log,
            name: "Scrub Seek",
            signpostID: signpostID,
            "target=%.3f",
            target
        )
        Task { [weak self, weak player] in
            guard let self, let player,
                self.player === player,
                self.isScrubbing,
                self.scrubSeekGeneration == seekGeneration,
                self.scrubSessionGeneration == sessionGeneration
            else { return }
            let didSeek = await self.boundedSeek(
                player: player,
                to: self.livePreviewPresentationTime(target),
                toleranceBefore: .zero,
                toleranceAfter: .zero,
                timeoutNanoseconds: 2_500_000_000
            )
            os_signpost(
                .end,
                log: TimelinePerformanceSignposts.log,
                name: "Scrub Seek",
                signpostID: signpostID
            )
            guard self.scrubSeekGeneration == seekGeneration else { return }
            self.recordScrubSeekLatency(CFAbsoluteTimeGetCurrent() - issuedAt)
            self.isScrubSeekInFlight = false
            if didSeek != .completed { self.lastIssuedScrubSeekTime = nil }
            guard didSeek != .timedOut else {
                if self.player === player {
                    self.schedulePreviewRecovery(
                        reason: .seekTimeout,
                        resumePlayback: false
                    )
                }
                return
            }
            guard self.isScrubbing else { return }
            if self.pendingScrubSeekTime != nil {
                self.scheduleLatestScrubSeek()
            }
        }
    }

    private func scrubSeekMinimumInterval() -> CFTimeInterval {
        // Pace new decoder work to the actual display, with a single seek in
        // flight. Cached frames bypass this path entirely. Layer-count guesses
        // must not force a capable device down to 24/30/45 Hz.
        1 / Double(max(livePreviewPresentation.maximumFramesPerSecond, 1))
    }

    private func recordScrubSeekLatency(_ latency: CFTimeInterval) {
        guard latency.isFinite, latency > 0 else { return }
        if scrubSeekLatencyEstimate == 0 {
            scrubSeekLatencyEstimate = latency
        } else {
            scrubSeekLatencyEstimate = scrubSeekLatencyEstimate * 0.75 + latency * 0.25
        }
    }

}
