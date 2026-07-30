// Scrubbing performance: coalesced seeks and deferred preview work.

import AVFoundation
import Foundation

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
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: scrubSeekTolerance(for: target),
            toleranceAfter: scrubSeekTolerance(for: target)
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.recordScrubSeekLatency(CFAbsoluteTimeGetCurrent() - issuedAt)
                guard self.scrubSeekGeneration == seekGeneration else { return }
                self.isScrubSeekInFlight = false
                guard self.isScrubbing else { return }
                if self.pendingScrubSeekTime != nil {
                    self.scheduleLatestScrubSeek()
                }
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
        project.tracks.reduce(0) { score, track in
            guard !track.isMuted,
                track.kind == .visual || track.kind == .shape || track.kind == .text
            else { return score }
            return score + track.items.reduce(0) { itemScore, item in
                guard item.timelineStart <= target && item.timelineEnd > target else {
                    return itemScore
                }
                switch item {
                case .shape:
                    return itemScore + 3
                case .text(let text):
                    var animatedTextCost = 0
                    if text.animations.entrance != nil { animatedTextCost += 2 }
                    if text.animations.loop != nil { animatedTextCost += 2 }
                    if text.animations.exit != nil { animatedTextCost += 2 }
                    let keyframeCost = min(text.allKeyframeTimes.count, 6)
                    return itemScore + 3 + animatedTextCost + keyframeCost
                default:
                    return itemScore
                }
            }
        }
    }
}
