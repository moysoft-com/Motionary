// Scrubbing performance: coalesced seeks and deferred preview work.

import AVFoundation
import Foundation
import os

extension EditorViewModel {
    func updateScrub(to time: Double) {
        let clamped = clampedTimelineTime(time)
        updateCurrentTime(clamped)
        guard isScrubbing else {
            seekPlayer(to: clamped, exact: false)
            return
        }

        pendingScrubSeekTime = clampedPlayableTime(clamped)
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
        guard pendingScrubSeekTime != nil else { return }
        guard scrubSeekTask == nil else { return }

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
        let tolerance = scrubSeekTolerance(for: target)
        Task { [weak self, weak player] in
            guard let self, let player else { return }
            let didSeek = await self.boundedSeek(
                player: player,
                to: target,
                toleranceBefore: tolerance,
                toleranceAfter: tolerance,
                timeoutNanoseconds: 700_000_000
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
            guard didSeek else {
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
        guard let target = pendingScrubSeekTime ?? lastIssuedScrubSeekTime else {
            return 1 / 60
        }
        let adaptiveInterval = scrubSeekAdaptiveInterval()
        let cost = activeGeneratedLayerCost(at: target)
        let costInterval: CFTimeInterval
        switch cost {
        case 0...4:
            costInterval = 1 / 60
        case 5...10:
            costInterval = 1 / 45
        default:
            costInterval = 1 / 30
        }
        return max(costInterval, adaptiveInterval)
    }

    private func scrubSeekTolerance(for target: Double) -> CMTime {
        let frameDuration = 1 / Double(max(project.renderSettings.frameRate, 1))
        let activeGeneratedLayerCost = activeGeneratedLayerCost(at: target)
        let tolerance = activeGeneratedLayerCost > 0
            ? max(frameDuration * 2, 1 / 15)
            : max(frameDuration, 1 / 30)
        return CMTime(seconds: tolerance, preferredTimescale: 600)
    }

    private func recordScrubSeekLatency(_ latency: CFTimeInterval) {
        guard latency.isFinite, latency > 0 else { return }
        if scrubSeekLatencyEstimate == 0 {
            scrubSeekLatencyEstimate = latency
        } else {
            scrubSeekLatencyEstimate = scrubSeekLatencyEstimate * 0.75 + latency * 0.25
        }
    }

    private func scrubSeekAdaptiveInterval() -> CFTimeInterval {
        switch scrubSeekLatencyEstimate {
        case 0..<0.055:
            return 1 / 60
        case 0.055..<0.095:
            return 1 / 45
        case 0.095..<0.16:
            return 1 / 30
        default:
            return 1 / 24
        }
    }

    private func activeGeneratedLayerCost(at target: Double) -> Int {
        cachedTimelineEvaluationIndex().generatedLayerCost(at: target)
    }
}
