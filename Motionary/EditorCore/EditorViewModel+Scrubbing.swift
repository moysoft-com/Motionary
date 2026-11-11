// Scrubbing performance: coalesced seeks and deferred preview work.

import AVFoundation
import Foundation
import os

extension EditorViewModel {
    func updateScrub(to time: Double) {
        guard !previewIsSuspended, !isPlaying, !playbackState.isStartingPlayback,
            !pendingPlaybackResumeAfterPreviewRebuild else { return }
        let clamped = clampedPlayableTime(time)
        let movement = clamped - currentTime
        if movement != 0 {
            lastScrubDirection = movement
            scrubPrefetchTask?.cancel()
            scrubPrefetchTask = nil
        }
        updateCurrentTime(clamped)
        guard isScrubbing else {
            seekPlayer(to: clamped, exact: false)
            return
        }

        scratchAudio.update(to: clamped)
        // A stale decoder graph cannot answer source-time requests after a
        // split, trim or ripple edit. The rebuild resumes this gesture at its
        // latest position as soon as the new graph is installed.
        guard !pendingPreviewInvalidation.contains(.compositionTopology) else { return }
        let frameDuration = 1 / Double(max(project.renderSettings.frameRate, 1))
        let target = currentScrubPresentationTime()
        if let frame = renderService.livePreviewState.cachedFrame(at: target,
                                                                  sessionID: previewRenderSessionID) {
            pendingScrubSeekTime = nil
            livePreviewPresentation.setFrame(frame, at: target)
            prefetchScrubNeighbors(from: target, frameDuration: frameDuration)
            return
        }
        // Only hold a nearby frame from the current edit revision. A pre-edit
        // timestamp may now refer to a different part of the source video.
        if let near = renderService.livePreviewState.cachedFrameNear(
            at: target, sessionID: previewRenderSessionID, window: frameDuration)
        {
            livePreviewPresentation.setFrame(near.frame, at: near.time)
        }
        pendingScrubSeekTime = target
        scheduleLatestScrubSeek()
    }

    /// At most one speculative GPU frame is submitted at a time. Delay it
    /// until input settles, and try the reverse neighbor as well for turnarounds.
    private func prefetchScrubNeighbors(from target: Double, frameDuration: Double) {
        guard isScrubbing, !isScrubSeekInFlight, scrubSeekTask == nil,
            scrubPrefetchTask == nil, !isRenderingPreview, !livePreviewFrameRefreshInFlight,
            ProcessInfo.processInfo.thermalState != .serious,
            ProcessInfo.processInfo.thermalState != .critical,
            abs(lastScrubDirection) > 0.000_001
        else { return }
        let direction: Double = lastScrubDirection > 0 ? 1 : -1
        let sessionID = previewRenderSessionID
        let generation = scrubSessionGeneration
        scrubPrefetchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(25))
            guard !Task.isCancelled, let self else { return }
            defer { if !Task.isCancelled { self.scrubPrefetchTask = nil } }
            for step in [direction, -direction] {
                guard !Task.isCancelled, self.scrubSessionGeneration == generation,
                    self.isScrubbing, !self.isScrubSeekInFlight,
                    self.previewRenderSessionID == sessionID,
                    self.currentScrubPresentationTime() == target
                else { return }
                let candidate = target + step * frameDuration
                guard candidate >= 0, candidate <= self.lastPlayableTime + 0.000_001 else { continue }
                let time = CMTime(seconds: candidate, preferredTimescale: max(self.project.renderSettings.frameRate, 1)).seconds
                let state = self.renderService.livePreviewState
                guard state.cachedFrame(at: time, sessionID: sessionID) == nil else { continue }
                let rendered: Bool = await withCheckedContinuation { continuation in
                    if !state.renderPausedFrame(at: time, sessionID: sessionID, completion: {
                        continuation.resume(returning: $0 != nil)
                    }) {
                        continuation.resume(returning: false)
                    }
                }
                if !rendered { return }
            }
        }
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
        // Generated/image-only intervals need no decoder movement. Reuse the
        // live Metal renderer at the requested time, at normal preview quality.
        if renderService.livePreviewState.renderPausedFrame(
            at: target, sessionID: previewRenderSessionID,
            completion: { [weak self, weak player] frame in
                Task { @MainActor in
                    guard let self, let player, self.player === player,
                        self.scrubSeekGeneration == seekGeneration,
                        self.scrubSessionGeneration == sessionGeneration else { return }
                    os_signpost(.end, log: TimelinePerformanceSignposts.log,
                                name: "Scrub Seek", signpostID: signpostID)
                    self.isScrubSeekInFlight = false
                    self.recordScrubSeekLatency(CFAbsoluteTimeGetCurrent() - issuedAt)
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
                    } else if frame != nil, self.currentScrubPresentationTime() == target {
                        self.prefetchScrubNeighbors(
                            from: target, frameDuration: 1 / Double(max(self.project.renderSettings.frameRate, 1)))
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

    func presentScrubFrame(_ frame: CVPixelBuffer, at time: Double) {
        let target = currentScrubPresentationTime()
        if let exact = renderService.livePreviewState.cachedFrame(at: target, sessionID: previewRenderSessionID) {
            livePreviewPresentation.setFrame(exact, at: target)
            return
        }
        // A late completion can move the preview towards the playhead during
        // fast scrubbing, provided it is closer than the frame already shown.
        if livePreviewPresentation.frame != nil, let displayed = livePreviewPresentation.frameTime,
            abs(displayed - target) <= abs(time - target)
        {
            return
        }
        livePreviewPresentation.setFrame(frame, at: time)
    }

    func currentScrubPresentationTime() -> Double {
        let frameRate = Double(max(project.renderSettings.frameRate, 1))
        return floor(clampedPlayableTime(currentTime) * frameRate + 0.000_001) / frameRate
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
