// Scrubbing performance: coalesced seeks and deferred preview work.

import AVFoundation
import Foundation
import os

extension EditorViewModel {
    func updateScrub(to time: Double) {
        guard !previewIsSuspended, !scrubIsFinishing, !isPlaying, !playbackState.isStartingPlayback,
            !pendingPlaybackResumeAfterPreviewRebuild else { return }
        let clamped = clampedTimelineTime(time)
        updateCurrentTime(clamped)
        guard isScrubbing else {
            seekPlayer(to: clamped, exact: false)
            return
        }

        scratchAudio.update(to: clamped)
        updateScrubPreview()
    }

    func updateScrubPreview() {
        // A stale decoder graph cannot answer source-time requests after a
        // split, trim or ripple edit. The rebuild resumes this gesture at its
        // latest position as soon as the new graph is installed.
        guard !screenRecordingPreview.freezesScrubPreview,
            !pendingPreviewInvalidation.contains(.compositionTopology) else { return }
        let target = currentScrubPresentationTime()
        if screenRecordingPreview.scrubFrameRateLimit != nil {
            // During a cadence experiment, cached frames use the same pacing as new renders.
            pendingScrubSeekTime = target
            scheduleLatestScrubSeek()
            return
        }
        let frameDuration = 1 / Double(max(project.renderSettings.frameRate, 1))
        if let frame = renderService.livePreviewState.cachedFrame(at: target,
                                                                  sessionID: previewRenderSessionID) {
            pendingScrubSeekTime = nil
            livePreviewPresentation.setFrame(frame, at: target)
            return
        }
        // Only hold a nearby frame from the current edit revision. A pre-edit
        // timestamp may now refer to a different part of the source video.
        if let near = renderService.livePreviewState.cachedFrameNear(
            at: target, sessionID: previewRenderSessionID, window: frameDuration)
        {
            presentScrubFrame(near.frame, at: near.time)
        }
        pendingScrubSeekTime = target
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
        guard !screenRecordingPreview.freezesScrubPreview,
            !pendingPreviewInvalidation.contains(.compositionTopology),
            let target = pendingScrubSeekTime, let player else { return }
        pendingScrubSeekTime = nil
        lastScrubUIUpdate = CFAbsoluteTimeGetCurrent()
        lastIssuedScrubSeekTime = target
        if screenRecordingPreview.scrubFrameRateLimit != nil,
            let cached = renderService.livePreviewState.cachedFrame(at: target, sessionID: previewRenderSessionID)
        {
            livePreviewPresentation.setFrame(cached, at: target)
            return
        }
        isScrubSeekInFlight = true
        scrubSeekGeneration &+= 1
        let seekGeneration = scrubSeekGeneration
        let sessionGeneration = scrubSessionGeneration
        let signpostID = OSSignpostID(log: TimelinePerformanceSignposts.log)
        os_signpost(
            .begin,
            log: TimelinePerformanceSignposts.log,
            name: "Scrub Seek",
            signpostID: signpostID,
            "target=%.3f",
            target
        )
        // Generated/image-only intervals need no decoder movement. Reuse the
        // live Metal renderer at the requested time.
        if renderService.livePreviewState.renderPausedFrame(
            at: target, sessionID: previewRenderSessionID,
            completion: { [weak self, weak player] frame in
                Task { @MainActor in
                    os_signpost(.end, log: TimelinePerformanceSignposts.log,
                                name: "Scrub Seek", signpostID: signpostID)
                    guard let self, let player, self.player === player,
                        self.scrubSeekGeneration == seekGeneration,
                        self.scrubSessionGeneration == sessionGeneration else { return }
                    self.isScrubSeekInFlight = false
                    guard self.isScrubbing else { return }
                    if let frame {
                        if self.renderService.livePreviewState.cachedFrame(
                            at: target, sessionID: self.previewRenderSessionID) === frame
                        {
                            self.presentScrubFrame(frame, at: target)
                        }
                    } else {
                        self.renderService.livePreviewState.clearPausedFrameRenderer()
                        self.lastIssuedScrubSeekTime = nil
                        if self.pendingScrubSeekTime == nil { self.pendingScrubSeekTime = target }
                    }
                    if self.pendingScrubSeekTime != nil {
                        self.scheduleLatestScrubSeek()
                    }
                }
            }
        ) { return }
        Task { [weak self, weak player] in
            guard let self, let player,
                self.player === player,
                self.isScrubbing,
                self.scrubSeekGeneration == seekGeneration,
                self.scrubSessionGeneration == sessionGeneration
            else { return }
            let didSeek = await self.boundedSeek(
                player: player,
                to: target,
                toleranceBefore: .zero,
                toleranceAfter: .zero,
                timeoutNanoseconds: 2_500_000_000,
                frameAligned: true
            )
            os_signpost(
                .end,
                log: TimelinePerformanceSignposts.log,
                name: "Scrub Seek",
                signpostID: signpostID
            )
            guard self.scrubSeekGeneration == seekGeneration else { return }
            self.isScrubSeekInFlight = false
            if didSeek != .completed { self.lastIssuedScrubSeekTime = nil }
            guard self.isScrubbing else { return }
            if didSeek == .completed,
                let frame = self.renderService.livePreviewState.cachedFrame(
                    at: target, sessionID: self.previewRenderSessionID)
            {
                self.presentScrubFrame(frame, at: target)
            }
            if self.pendingScrubSeekTime != nil {
                self.scheduleLatestScrubSeek()
            }
        }
    }

    func presentScrubFrame(_ frame: CVPixelBuffer, at time: Double) {
        guard !pendingPreviewInvalidation.contains(.compositionTopology) else { return }
        guard !screenRecordingPreview.freezesScrubPreview || scrubIsFinishing else { return }
        let target = currentScrubPresentationTime()
        if let exact = renderService.livePreviewState.cachedFrame(at: target, sessionID: previewRenderSessionID) {
            livePreviewPresentation.setFrame(exact, at: target)
            return
        }
        guard !scrubIsFinishing else { return }
        // Timeline distance grows with gesture speed even at constant render
        // latency. Accept progress toward the current target, while rejecting
        // completions that would go backwards or overshoot after a reversal.
        if let displayed = livePreviewPresentation.frameTime {
            guard (displayed < time && time <= target) || (target <= time && time < displayed) else { return }
        }
        livePreviewPresentation.setFrame(frame, at: time)
    }

    func currentScrubPresentationTime() -> Double {
        canonicalPreviewFrameTime(currentTime)
    }

    private func scrubSeekMinimumInterval() -> CFTimeInterval {
        // Pace new decoder work to the actual display, with a single seek in
        // flight. Cached frames normally bypass this path. Layer-count guesses
        // must not force a capable device down to 24/30/45 Hz.
        let native = livePreviewPresentation.maximumFramesPerSecond
        let limit = screenRecordingPreview.scrubFrameRateLimit ?? native
        return 1 / Double(max(min(native, limit), 1))
    }

}
