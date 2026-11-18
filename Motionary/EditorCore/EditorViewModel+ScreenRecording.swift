import Foundation

struct ScreenRecordingPreviewConfiguration: Equatable {
    var freezesScrubPreview = false
    var hidesCanvasOverlays = false
    var effectDimension: Int?
    var scrubFrameRateLimit: Int?
}

extension EditorViewModel {
    func configureScreenRecordingPreview(_ configuration: ScreenRecordingPreviewConfiguration) {
        let previous = screenRecordingPreview
        guard configuration != previous else { return }
        screenRecordingPreview = configuration

        let effectBudgetChanged = configuration.effectDimension != previous.effectDimension
        if effectBudgetChanged {
            renderService.livePreviewState.setScreenRecordingEffectDimension(configuration.effectDimension)
        }

        if isScrubbing {
            guard !scrubIsFinishing else { return }
            let freezeChanged = configuration.freezesScrubPreview != previous.freezesScrubPreview
            let cadenceChanged = configuration.scrubFrameRateLimit != previous.scrubFrameRateLimit
            guard effectBudgetChanged || freezeChanged || cadenceChanged else { return }
            scrubSeekTask?.cancel()
            scrubSeekTask = nil
            pendingScrubSeekTime = nil
            lastIssuedScrubSeekTime = nil
            lastScrubUIUpdate = 0
            if configuration.freezesScrubPreview {
                if isScrubSeekInFlight {
                    scrubSeekGeneration &+= 1
                    isScrubSeekInFlight = false
                    player?.currentItem?.cancelPendingSeeks()
                }
            } else {
                updateScrubPreview()
            }
        } else if effectBudgetChanged, !isPlaying, !previewIsSuspended,
            player?.currentItem?.videoComposition != nil
        {
            pendingLivePreviewFrameRefresh = true
            enqueueLivePreviewFrameRefresh()
        }
    }
}
