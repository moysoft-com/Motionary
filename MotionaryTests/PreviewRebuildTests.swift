import AVFoundation
import Foundation
import Testing

@testable import Motionary

@Suite(.serialized)
struct PreviewRebuildTests {
    @MainActor
    @Test func generatedCustomCompositionPreviewPlayerAdvances() async throws {
        let shape = ShapeTimelineItem(
            name: "Clocked preview",
            mediaID: MediaID(),
            shape: ClipShape(
                kind: .rectangle,
                color: .white,
                width: 64,
                height: 64
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        let project = EditorProject(
            title: "Clocked preview",
            renderSettings: RenderSettings(width: 96, height: 128, frameRate: 30),
            tracks: [
                TimelineTrack(
                    name: "Shape",
                    kind: .shape,
                    items: [.shape(shape)]
                )
            ]
        )
        let prepared = try #require(
            try await CompositionRenderService().preparePreview(
                for: project,
                quality: .interactive,
                invalidation: [.previewFrame, .compositionTopology, .audioMix]
            )
        )
        let item = AVPlayerItem(asset: prepared.composition)
        let videoComposition = try #require(prepared.videoComposition)
        #expect(videoComposition.sourceTrackIDForFrameTiming > 0)
        let imageGenerator = AVAssetImageGenerator(asset: prepared.composition)
        imageGenerator.videoComposition = videoComposition
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero
        let renderedFrame = try await imageGenerator.image(
            at: CMTime(seconds: 1 / 30, preferredTimescale: 600)
        ).image
        #expect(renderedFrame.width == 96)
        #expect(renderedFrame.height == 128)
        item.videoComposition = videoComposition
        let player = AVPlayer(playerItem: item)
        let observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { _ in }
        defer {
            player.pause()
            player.removeTimeObserver(observer)
        }

        await withCheckedContinuation { continuation in
            player.seek(
                to: CMTime(seconds: 1 / 30, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                continuation.resume()
            }
        }
        player.play()

        for _ in 0..<200 {
            if CMTimeGetSeconds(player.currentTime()) > 0.1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        if item.status == .failed {
            let itemError = item.error as NSError?
            let playerError = player.error as NSError?
            let events = item.errorLog()?.events.map { event in
                "domain=\(event.errorDomain) code=\(event.errorStatusCode) "
                    + "comment=\(event.errorComment ?? "nil")"
            } ?? []
            let diagnostic = "AVPlayerItem failed: \(String(describing: itemError)); "
                + "userInfo=\(String(describing: itemError?.userInfo)); "
                + "player=\(String(describing: playerError)); "
                + events.joined(separator: " | ")
            Issue.record(Comment(rawValue: diagnostic))
        }
        #expect(item.status == .readyToPlay)
        #expect(CMTimeGetSeconds(player.currentTime()) > 0.1)
    }

    @Test func renderInvalidationDetectsVisualOnlyChanges() async throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/visual.mov"),
            mediaType: .video,
            originalDuration: 4
        )
        let before = TimelineClip(
            name: "Clip",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4)
        )
        var after = before
        after.transform.opacity = AnimatableProperty(baseValue: 0.5)

        let invalidation = EditorProject.renderInvalidation(before: before, after: after)
        #expect(invalidation.contains(.previewFrame))
        #expect(!invalidation.contains(.compositionTopology))
        #expect(!invalidation.contains(.audioMix))
    }

    @Test func renderInvalidationDetectsAudioOnlyChanges() async throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/audio.mov"),
            mediaType: .video,
            originalDuration: 3
        )
        let before = TimelineClip(
            name: "Clip",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 3)
        )
        var after = before
        after.volume = AnimatableProperty(baseValue: 0.25)

        let invalidation = EditorProject.renderInvalidation(before: before, after: after)
        #expect(invalidation.contains(.audioMix))
        #expect(!invalidation.contains(.compositionTopology))
    }

    @Test func adjustmentVisualChangeInvalidatesPreviewWithoutRebuildingTopology() throws {
        let adjustment = AdjustmentTimelineItem(
            timelineStart: 0,
            duration: 4
        )
        let before = EditorProject(
            title: "Adjustment invalidation",
            tracks: [
                TimelineTrack(
                    name: "Adjustment",
                    kind: .visual,
                    items: [.adjustment(adjustment)]
                )
            ]
        )
        var after = before
        var updatedItem = try #require(after.item(id: adjustment.id))
        var visuals = try #require(updatedItem.editableVisuals)
        visuals.adjustments.saturation = AnimatableProperty(baseValue: 0.25)
        updatedItem.editableVisuals = visuals
        after.replaceItem(id: adjustment.id, with: updatedItem)

        let invalidation = after.renderInvalidation(comparedTo: before)

        #expect(invalidation.contains(.previewFrame))
        #expect(!invalidation.contains(.compositionTopology))
        #expect(!invalidation.contains(.audioMix))
    }

    @Test func replaceClipCommandUsesCompactUndoPayload() async throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/compact.mov"),
            mediaType: .video,
            originalDuration: 2
        )
        let before = TimelineClip(
            name: "Clip",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        var after = before
        after.transform.opacity = AnimatableProperty(baseValue: 0.4)
        let command = EditorCommandFactory.replaceClip(
            before: before,
            after: after,
            invalidation: [.previewFrame]
        )
        var project = EditorProject(
            title: "Compact",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [before])]
        )
        project.registerMedia(from: source, mediaID: before.mediaID)

        command.apply(to: &project)
        #expect(project.tracks[0].clips[0].transform.opacity.baseValue == 0.4)

        command.undo(on: &project)
        #expect(project.tracks[0].clips[0].transform.opacity.baseValue == 1)
    }

    @Test func timelineClipEncodesWithoutEmbeddedSource() async throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/encode.mov"),
            mediaType: .video,
            originalDuration: 2
        )
        let clip = TimelineClip(
            name: "Clip",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        var project = EditorProject(
            title: "Encode",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        project.registerMedia(from: source, mediaID: clip.mediaID)
        let data = try JSONEncoder().encode(ProjectContent(editorProject: project))
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("\"source\""))
        #expect(json.contains("\"mediaID\""))
    }

    @MainActor
    @Test func interactivePreviewInvalidationsCoalesceWhileRendererIsBusy() async throws {
        let viewModel = makeViewModel()
        defer {
            viewModel.cancelInteractivePreviewRebuild()
            viewModel.isRenderingPreview = false
            viewModel.stop()
        }
        viewModel.isRenderingPreview = true

        viewModel.scheduleInteractivePreviewRebuild(invalidation: [.previewFrame])
        viewModel.scheduleInteractivePreviewRebuild(invalidation: [.audioMix])

        #expect(viewModel.previewQuality == .interactive)
        #expect(viewModel.pendingInteractivePreviewInvalidation.contains(.previewFrame))
        #expect(viewModel.pendingInteractivePreviewInvalidation.contains(.audioMix))
        #expect(viewModel.interactivePreviewThrottleTask != nil)
    }

    @MainActor
    @Test func interactiveAudioEditUsesTrackLocalMixWithoutRebuildOrSeekPath() async throws {
        let audioURL = try makeSilentAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Live audio",
            source: ClipSource(
                url: audioURL,
                mediaType: .audio,
                originalDuration: 1
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        let viewModel = makeViewModel(clip: clip)
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }
        let preparedPreview = try #require(
            try await viewModel.renderService.preparePreview(
                for: viewModel.project,
                quality: .balanced,
                invalidation: [.previewFrame, .compositionTopology, .audioMix]
            )
        )
        let playerItem = AVPlayerItem(asset: preparedPreview.composition)
        playerItem.audioMix = preparedPreview.audioMix
        let initialMix = try #require(playerItem.audioMix)
        viewModel.player = AVPlayer(playerItem: playerItem)
        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)

        viewModel.setSelectedKeyframeValue(
            0.25,
            target: .volume,
            interactive: true
        )

        #expect(viewModel.previewQuality == .balanced)
        #expect(viewModel.pendingInteractivePreviewInvalidation.isEmpty)
        #expect(viewModel.interactivePreviewThrottleTask == nil)
        #expect(viewModel.rebuildTask == nil)
        #expect(viewModel.undoStack.isEmpty)

        for _ in 0..<100 {
            if let audioMix = playerItem.audioMix, audioMix !== initialMix,
                viewModel.liveAudioPreviewTask == nil
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let liveMix = try #require(playerItem.audioMix)
        #expect(liveMix !== initialMix)
        #expect(viewModel.liveAudioPreviewTask == nil)
        #expect(viewModel.pendingLiveAudioPreviewItemID == nil)

        var startVolume: Float = 0
        var endVolume: Float = 0
        var timeRange = CMTimeRange.invalid
        let parameters = try #require(liveMix.inputParameters.first)
        let hasRamp = parameters.getVolumeRamp(
            for: CMTime(seconds: 0.5, preferredTimescale: 600),
            startVolume: &startVolume,
            endVolume: &endVolume,
            timeRange: &timeRange
        )
        #expect(hasRamp)
        #expect(abs(Double(startVolume) - 0.25) < 0.000_1)
        #expect(abs(Double(endVolume) - 0.25) < 0.000_1)

        viewModel.setSelectedKeyframeValue(
            0.5,
            target: .volume,
            interactive: true
        )
        #expect(viewModel.liveAudioPreviewTask != nil)
        viewModel.cancelInteractivePreviewRebuild()
        #expect(viewModel.liveAudioPreviewTask == nil)
        #expect(viewModel.pendingLiveAudioPreviewItemID == nil)

        viewModel.setSelectedKeyframeValue(
            0.6,
            target: .volume,
            interactive: true
        )
        let replacementGeneration = viewModel.liveAudioPreviewTaskGeneration
        for _ in 0..<8 {
            await Task.yield()
        }
        #expect(viewModel.liveAudioPreviewTask != nil)
        #expect(viewModel.liveAudioPreviewTaskGeneration == replacementGeneration)
        viewModel.cancelInteractivePreviewRebuild()

        viewModel.finishInteractiveEdit(rebuild: false)
        #expect(viewModel.undoStack.count == 1)

        viewModel.setSelectedKeyframeValue(
            0.75,
            target: .volume,
            interactive: true
        )
        #expect(viewModel.liveAudioPreviewTask != nil)
        viewModel.project.tracks[0].items.removeAll()
        try await Task.sleep(for: .milliseconds(80))
        #expect(viewModel.liveAudioPreviewTask == nil)
        #expect(viewModel.pendingLiveAudioPreviewItemID == nil)
    }

    @MainActor
    @Test func interactiveEditCommitReturnsToBalancedQualityAndRecordsOneUndo() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Interactive",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/interactive.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let viewModel = makeViewModel(clip: clip)
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }
        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)
        viewModel.isRenderingPreview = true

        viewModel.setSelectedKeyframeValue(0.5, target: .positionX, interactive: true)
        #expect(viewModel.previewQuality == .interactive)
        #expect(viewModel.renderService.livePreviewState.usesInteractiveQuality)
        #expect(viewModel.undoStack.isEmpty)
        #expect(viewModel.pendingInteractivePreviewInvalidation.isEmpty)
        #expect(viewModel.interactivePreviewThrottleTask == nil)
        #expect(viewModel.rebuildTask == nil)
        #expect(viewModel.pendingLiveVisualOverrideItemIDs == [clipID])
        let liveOverride = try #require(
            viewModel.renderService.livePreviewState.override(for: clipID)
        )
        let liveVisuals = try #require(liveOverride.visuals)
        #expect(liveVisuals.transform.positionX.value(at: 0) == 0.5)

        viewModel.isRenderingPreview = false
        viewModel.finishInteractiveEdit()

        #expect(viewModel.previewQuality == .balanced)
        #expect(!viewModel.renderService.livePreviewState.usesInteractiveQuality)
        #expect(viewModel.pendingInteractivePreviewInvalidation.isEmpty)
        #expect(viewModel.pendingLiveVisualOverrideItemIDs == [clipID])
        #expect(viewModel.renderService.livePreviewState.hasActiveOverrides)
        #expect(viewModel.rebuildTask != nil)
        #expect(viewModel.undoStack.count == 1)
    }

    @MainActor
    @Test func playbackStartCancelsPendingDelayedPreviewRebuild() async throws {
        let shape = ShapeTimelineItem(
            name: "Play Race",
            mediaID: MediaID(),
            shape: ClipShape(
                kind: .rectangle,
                color: .white,
                width: 64,
                height: 64
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(
                editorProject: EditorProject(
                    title: "Play Race",
                    renderSettings: RenderSettings(width: 96, height: 128, frameRate: 30),
                    tracks: [
                        TimelineTrack(
                            name: "Shape",
                            kind: .shape,
                            items: [.shape(shape)]
                        )
                    ]
                )
            )
        )
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }
        let preparedPreview = try #require(
            try await viewModel.renderService.preparePreview(
                for: viewModel.project,
                quality: .balanced,
                invalidation: [.previewFrame, .compositionTopology, .audioMix]
            )
        )
        let playerItem = AVPlayerItem(asset: preparedPreview.composition)
        playerItem.videoComposition = preparedPreview.videoComposition
        playerItem.audioMix = preparedPreview.audioMix
        viewModel.player = AVPlayer(playerItem: playerItem)
        viewModel.updateCurrentTime(0.25)
        let previewGeneration = viewModel.previewGeneration

        viewModel.schedulePreviewRebuild(
            seekTo: 0,
            delay: true,
            invalidation: [.previewFrame]
        )
        let delayedRebuild = try #require(viewModel.rebuildTask)

        viewModel.togglePlayback()

        #expect(delayedRebuild.isCancelled)
        #expect(viewModel.rebuildTask == nil)
        #expect(viewModel.previewGeneration == previewGeneration + 2)
        #expect(viewModel.isPlaying)
        #expect(viewModel.currentTime == 0.25)
    }

    @MainActor
    @Test func playbackPauseClearsUIStateImmediately() async throws {
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(
                editorProject: EditorProject.empty(title: "Pause")
            )
        )
        defer {
            viewModel.player?.pause()
            viewModel.stop()
        }
        viewModel.player = AVPlayer()
        viewModel.isPlaying = true

        viewModel.togglePlayback()

        #expect(!viewModel.isPlaying)
        #expect(!viewModel.isScrubbing)
        #expect(!viewModel.pendingPlaybackResumeAfterPreviewRebuild)
    }

    @MainActor
    @Test func playbackPauseCancelsRebuildWithoutEnteringScrubState() async throws {
        let viewModel = makeGeneratedLayerViewModel()
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }
        viewModel.player = AVPlayer()
        viewModel.isPlaying = true
        let staleTask = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(10))
        }
        viewModel.rebuildTask = staleTask

        viewModel.togglePlayback()

        #expect(staleTask.isCancelled)
        #expect(!viewModel.isPlaying)
        #expect(!viewModel.isScrubbing)
        #expect(!viewModel.pendingPlaybackResumeAfterPreviewRebuild)
        #expect(viewModel.deferredPreviewInvalidation.isEmpty)
    }

    @MainActor
    @Test func stalePreviewItemNotificationsDoNotTriggerRecovery() async throws {
        let viewModel = makeGeneratedLayerViewModel()
        defer {
            viewModel.previewRecoveryTask?.cancel()
            viewModel.stop()
        }
        let oldItem = AVPlayerItem(asset: AVMutableComposition())
        let newItem = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: oldItem)
        viewModel.player = player
        viewModel.installPreviewItemHealthObservers(for: oldItem)
        player.replaceCurrentItem(with: newItem)
        viewModel.installPreviewItemHealthObservers(for: newItem)

        NotificationCenter.default.post(
            name: .AVPlayerItemPlaybackStalled,
            object: oldItem
        )
        await Task.yield()

        #expect(viewModel.previewRecoveryAttemptCount == 0)

        NotificationCenter.default.post(
            name: .AVPlayerItemPlaybackStalled,
            object: newItem
        )
        await Task.yield()

        #expect(viewModel.previewRecoveryAttemptCount == 1)
    }

    @MainActor
    @Test func staleCompositorFailureDoesNotTriggerCurrentPreviewRecovery() async throws {
        let viewModel = makeGeneratedLayerViewModel()
        defer {
            viewModel.previewRecoveryTask?.cancel()
            viewModel.stop()
        }
        let item = AVPlayerItem(asset: AVMutableComposition())
        viewModel.replacePreviewPlayer(with: item)
        viewModel.installPreviewItemHealthObservers(for: item)
        let currentSession = viewModel.previewRenderSessionID

        NotificationCenter.default.post(
            name: .motionaryVideoCompositorPersistentFailure,
            object: nil,
            userInfo: ["renderSessionID": UUID()]
        )
        await Task.yield()

        #expect(viewModel.previewRecoveryAttemptCount == 0)

        NotificationCenter.default.post(
            name: .motionaryVideoCompositorPersistentFailure,
            object: nil,
            userInfo: ["renderSessionID": currentSession]
        )
        await Task.yield()

        #expect(viewModel.previewRecoveryAttemptCount == 1)
    }

    @MainActor
    @Test func replacingPreviewPlayerRotatesVisibleRendererIdentity() async throws {
        let viewModel = makeGeneratedLayerViewModel()
        defer { viewModel.stop() }
        let firstIdentity = viewModel.previewRendererIdentity
        let firstItem = AVPlayerItem(asset: AVMutableComposition())
        viewModel.replacePreviewPlayer(with: firstItem)
        let firstPlayer = try #require(viewModel.player)
        let secondIdentity = viewModel.previewRendererIdentity

        #expect(secondIdentity != firstIdentity)

        let secondItem = AVPlayerItem(asset: AVMutableComposition())
        viewModel.replacePreviewPlayer(with: secondItem)

        #expect(viewModel.player !== firstPlayer)
        #expect(viewModel.player?.currentItem === secondItem)
        #expect(viewModel.previewRendererIdentity != secondIdentity)
    }

    @MainActor
    @Test func repeatedPreviewRecoveryOpensCircuitInsteadOfLoopingForever() async throws {
        let viewModel = makeGeneratedLayerViewModel()
        defer { viewModel.stop() }
        viewModel.player = AVPlayer()
        viewModel.isPlaying = true

        viewModel.schedulePreviewRecovery(reason: .playerItemFailed, resumePlayback: true)
        viewModel.schedulePreviewRecovery(reason: .playerItemFailed, resumePlayback: true)
        viewModel.schedulePreviewRecovery(reason: .playerItemFailed, resumePlayback: true)
        viewModel.schedulePreviewRecovery(reason: .playerItemFailed, resumePlayback: true)
        await Task.yield()

        #expect(viewModel.previewRecoveryCircuitIsOpen)
        #expect(viewModel.player == nil)
        #expect(!viewModel.isPlaying)
        #expect(!viewModel.isScrubbing)
        if case .failed = viewModel.previewState.status {
            #expect(true)
        } else {
            Issue.record("Expected preview recovery circuit to mark preview as failed.")
        }
    }

    @MainActor
    @Test func previewRebuildAfterRecoveryCircuitRevivesRenderer() async throws {
        let viewModel = makeGeneratedLayerViewModel()
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }
        viewModel.player = AVPlayer()

        viewModel.schedulePreviewRecovery(reason: .playerItemFailed, resumePlayback: false)
        viewModel.schedulePreviewRecovery(reason: .playerItemFailed, resumePlayback: false)
        viewModel.schedulePreviewRecovery(reason: .playerItemFailed, resumePlayback: false)
        viewModel.schedulePreviewRecovery(reason: .playerItemFailed, resumePlayback: false)
        await Task.yield()
        #expect(viewModel.previewRecoveryCircuitIsOpen)

        viewModel.schedulePreviewRebuild(seekTo: 0.2, delay: false, invalidation: [.previewFrame])

        #expect(!viewModel.previewRecoveryCircuitIsOpen)
        #expect(viewModel.rebuildTask != nil)
    }

    @MainActor
    @Test func pureVisualEditCancelsAnOlderDescriptorGeneration() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Generation",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/generation.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let viewModel = makeViewModel(clip: clip)
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }
        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)
        viewModel.beginInteractiveEdit()
        let staleTask = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(10))
        }
        viewModel.rebuildTask = staleTask
        let generation = viewModel.previewGeneration

        viewModel.setSelectedKeyframeValue(0.25, target: .opacity, interactive: true)

        #expect(staleTask.isCancelled)
        #expect(viewModel.rebuildTask == nil)
        #expect(viewModel.previewGeneration == generation + 1)
        #expect(viewModel.pendingLiveVisualOverrideItemIDs == [clipID])
    }

    @MainActor
    @Test func textInspectorPublishesCompleteLivePayloadWithoutRebuild() async throws {
        let text = TextTimelineItem(
            text: "Live",
            timelineStart: 0,
            duration: 2
        )
        let track = TimelineTrack(
            name: "Text",
            kind: .text,
            items: [.text(text)]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(
                editorProject: EditorProject(
                    title: "Live text",
                    tracks: [track]
                )
            )
        )
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }
        viewModel.selectTimelineItem(text.id, trackID: track.id)

        viewModel.setSelectedTextKeyframeValue(
            96,
            target: .textFontSize,
            interactive: true
        )

        let liveOverride = try #require(
            viewModel.renderService.livePreviewState.override(for: text.id)
        )
        let liveText = try #require(liveOverride.text)
        #expect(liveText.style.fontSize == 96)
        #expect(liveOverride.visuals != nil)
        #expect(viewModel.pendingInteractivePreviewInvalidation.isEmpty)
        #expect(viewModel.interactivePreviewThrottleTask == nil)
        #expect(viewModel.rebuildTask == nil)
    }

    @MainActor
    @Test func scrubRestoreUnionsGeneratedFrameWithDeferredTopologyAndAudio() {
        let shape = ShapeTimelineItem(
            name: "Generated",
            mediaID: MediaID(),
            shape: ClipShape(
                kind: .rectangle,
                color: .white,
                width: 100,
                height: 100
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(
                editorProject: EditorProject(
                    title: "Scrub union",
                    tracks: [
                        TimelineTrack(
                            name: "Shape",
                            kind: .shape,
                            items: [.shape(shape)]
                        )
                    ]
                )
            )
        )
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }
        viewModel.deferredPreviewInvalidation = [
            .compositionTopology,
            .audioMix,
        ]
        let generation = viewModel.previewGeneration

        let scheduled = viewModel.flushDeferredPreviewRebuild(
            seekTo: 0,
            includeGeneratedLayerQualityRestore: true
        )

        #expect(scheduled.contains(.previewFrame))
        #expect(scheduled.contains(.compositionTopology))
        #expect(scheduled.contains(.audioMix))
        #expect(viewModel.deferredPreviewInvalidation.isEmpty)
        #expect(viewModel.previewGeneration == generation + 1)
        #expect(viewModel.rebuildTask != nil)
    }

    @MainActor
    @Test func externalCommandCarriesPrecedingInteractiveRenderInvalidation() {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Combined invalidation",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/combined-invalidation.mov"),
                mediaType: .video,
                originalDuration: 8
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4)
        )
        let viewModel = makeViewModel(clip: clip)
        defer {
            viewModel.isScrubbing = false
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }
        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)
        viewModel.beginInteractiveEdit()
        viewModel.mutateProject(
            rebuild: false,
            recordHistory: false,
            persistChanges: false,
            touchUpdatedAt: false
        ) { project in
            guard case .media(var item) = project.item(id: clipID) else { return }
            item.speedMap = .constant(speed: 2)
            project.replaceItem(id: clipID, with: .media(item))
        }
        viewModel.isScrubbing = true

        viewModel.mutateProject { project in
            guard var item = project.item(id: clipID),
                var visuals = item.editableVisuals
            else { return }
            visuals.transform.opacity.baseValue = 0.5
            item.editableVisuals = visuals
            project.replaceItem(id: clipID, with: item)
        }

        #expect(viewModel.interactiveEditSnapshot == nil)
        #expect(viewModel.undoStack.count == 2)
        #expect(viewModel.deferredPreviewInvalidation.contains(.previewFrame))
        #expect(viewModel.deferredPreviewInvalidation.contains(.compositionTopology))
        #expect(viewModel.deferredPreviewInvalidation.contains(.audioMix))
    }

    @MainActor
    @Test func noOpInteractiveEditClearsItsLiveVisualOverride() throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "No-op",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/no-op.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let viewModel = makeViewModel(clip: clip)
        defer { viewModel.stop() }
        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)
        viewModel.beginInteractiveEdit()
        viewModel.scheduleInteractivePreviewRebuild(invalidation: [.previewFrame])
        #expect(viewModel.renderService.livePreviewState.hasActiveOverrides)

        viewModel.finishInteractiveEdit(rebuild: false)

        #expect(viewModel.pendingLiveVisualOverrideItemIDs.isEmpty)
        #expect(!viewModel.renderService.livePreviewState.hasActiveOverrides)
        #expect(viewModel.undoStack.isEmpty)
    }

    @MainActor
    @Test func livePreviewCommitKeepsOverrideUntilExplicitFreshFrameAcknowledgement() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Live Override",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/live-override.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let viewModel = makeViewModel(clip: clip)
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }

        viewModel.updateLivePreviewTransform(
            clip.transform,
            for: clipID,
            hidden: true,
            immediate: false
        )
        #expect(viewModel.renderService.livePreviewState.hasActiveOverrides)
        #expect(viewModel.renderService.livePreviewState.usesInteractiveQuality)

        let existingRebuild = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(10))
        }
        viewModel.rebuildTask = existingRebuild
        let generation = viewModel.previewGeneration
        viewModel.prepareLivePreviewCommitPresentation(for: clipID)

        #expect(viewModel.renderService.livePreviewState.hasActiveOverrides)
        #expect(viewModel.renderService.livePreviewState.isHidden(clipID) == false)
        #expect(!viewModel.renderService.livePreviewState.usesInteractiveQuality)
        #expect(viewModel.previewQuality == .balanced)
        #expect(!existingRebuild.isCancelled)
        #expect(viewModel.previewGeneration == generation)

        try await Task.sleep(for: .milliseconds(420))

        #expect(viewModel.renderService.livePreviewState.hasActiveOverrides)
        viewModel.completeLivePreviewCommitPresentation(for: clipID)
        #expect(!viewModel.renderService.livePreviewState.hasActiveOverrides)
        #expect(!viewModel.renderService.livePreviewState.usesInteractiveQuality)
        #expect(viewModel.previewQuality == .balanced)
    }

    @MainActor
    @Test func livePreviewProxyHandoffRevealsCanonicalSourceBeforeAcknowledgement() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Proxy Handoff",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/proxy-handoff.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let viewModel = makeViewModel(clip: clip)
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }

        viewModel.updateLivePreviewTransform(
            clip.transform,
            for: clipID,
            hidden: true,
            immediate: false
        )

        viewModel.prepareLivePreviewCommitPresentation(for: clipID)

        #expect(viewModel.renderService.livePreviewState.hasActiveOverrides)
        #expect(!viewModel.renderService.livePreviewState.isHidden(clipID))
        #expect(!viewModel.renderService.livePreviewState.usesInteractiveQuality)
        #expect(viewModel.previewQuality == .balanced)

        viewModel.completeLivePreviewCommitPresentation(for: clipID)
        #expect(!viewModel.renderService.livePreviewState.hasActiveOverrides)
    }

    @MainActor
    @Test func directPreviewTransformStartsInteractiveFrameWhenPlayerIsMissing() throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Live Transform",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/live-transform.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let viewModel = makeViewModel(clip: clip)
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }
        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)
        var transform = clip.transform
        transform.positionX.baseValue = 0.4
        let generation = viewModel.previewGeneration

        viewModel.updateLivePreviewTransform(
            transform,
            for: clipID,
            immediate: true
        )

        let liveTransform = try #require(
            viewModel.renderService.livePreviewState.transform(for: clipID)
        )
        #expect(liveTransform.positionX.baseValue == 0.4)
        #expect(viewModel.previewQuality == .interactive)
        #expect(viewModel.rebuildTask != nil)
        #expect(viewModel.previewGeneration == generation + 1)
        #expect(!viewModel.pendingLivePreviewFrameRefresh)
        #expect(!viewModel.livePreviewFrameRefreshInFlight)
        #expect(viewModel.undoStack.isEmpty)
    }

    @MainActor
    @Test func previewTopologyRebuildsWhenCanvasGeometryChanges() async throws {
        let text = TextTimelineItem(
            text: "Canvas",
            timelineStart: 0,
            duration: 1
        )
        var project = EditorProject(
            title: "Canvas topology",
            renderSettings: RenderSettings(width: 320, height: 480, frameRate: 30),
            tracks: [
                TimelineTrack(
                    name: "Text",
                    kind: .text,
                    items: [.text(text)]
                )
            ]
        )
        let service = CompositionRenderService()

        let first = try await service.preparePreview(
            for: project,
            quality: .balanced,
            invalidation: [.previewFrame, .compositionTopology, .audioMix]
        )
        project.renderSettings = RenderSettings(width: 480, height: 320, frameRate: 30)
        let second = try await service.preparePreview(
            for: project,
            quality: .balanced,
            invalidation: [.previewFrame]
        )

        #expect(first?.topologyWasRebuilt == true)
        #expect(second?.topologyWasRebuilt == true)
    }

    @MainActor
    @Test func preparedPreviewCarriesRenderSessionIDIntoInstruction() async throws {
        let sessionID = UUID()
        let service = CompositionRenderService()
        let project = EditorProject(
            title: "Session",
            renderSettings: RenderSettings(width: 96, height: 128, frameRate: 30),
            tracks: [
                TimelineTrack(
                    name: "Text",
                    kind: .text,
                    items: [
                        .text(
                            TextTimelineItem(
                                text: "Session",
                                timelineStart: 0,
                                duration: 1
                            )
                        )
                    ]
                )
            ]
        )

        let prepared = try await service.preparePreview(
            for: project,
            quality: .balanced,
            invalidation: [.previewFrame, .compositionTopology],
            renderSessionID: sessionID
        )
        let instruction = try #require(
            prepared?.videoComposition?.instructions.first
                as? MotionaryVideoCompositionInstruction
        )

        #expect(instruction.renderSessionID == sessionID)
    }

    @MainActor
    @Test func interactivePreviewUsesDisplaySizedGeneratedLayerProxy() async throws {
        let text = TextTimelineItem(
            text: "Interactive",
            timelineStart: 0,
            duration: 1
        )
        let project = EditorProject(
            title: "Interactive Raster Scale",
            renderSettings: RenderSettings(width: 1080, height: 1920, frameRate: 30),
            tracks: [
                TimelineTrack(
                    name: "Text",
                    kind: .text,
                    items: [.text(text)]
                )
            ]
        )
        let service = CompositionRenderService()

        let prepared = try await service.preparePreview(
            for: project,
            quality: .interactive,
            invalidation: [.previewFrame, .compositionTopology]
        )
        let instruction = try #require(
            prepared?.videoComposition?.instructions.first
                as? MotionaryVideoCompositionInstruction
        )

        #expect(instruction.renderSize == CGSize(width: 404, height: 720))
        #expect(abs(instruction.renderScale - 404.0 / 1080.0) < 0.000_001)
        #expect(instruction.vectorRenderScale == instruction.renderScale)
    }

    @MainActor
    @Test func interactivePreviewScalesEffectGeometryWithProxyResolution() async throws {
        let text = TextTimelineItem(
            text: "Dense scrub",
            timelineStart: 0,
            duration: 1
        )
        let project = EditorProject(
            title: "Interactive Preview Resolution",
            renderSettings: RenderSettings(width: 1080, height: 1920, frameRate: 30),
            tracks: [
                TimelineTrack(
                    name: "Text",
                    kind: .text,
                    items: [.text(text)]
                )
            ]
        )
        let service = CompositionRenderService()

        let prepared = try await service.preparePreview(
            for: project,
            quality: .interactive,
            invalidation: [.previewFrame, .compositionTopology]
        )
        let instruction = try #require(
            prepared?.videoComposition?.instructions.first
                as? MotionaryVideoCompositionInstruction
        )

        #expect(instruction.renderSize == CGSize(width: 404, height: 720))
        #expect(abs(instruction.renderScale - 404.0 / 1080.0) < 0.000_001)
        #expect(instruction.vectorRenderScale == instruction.renderScale)
        #expect(instruction.qualityProfile == .interactive)
    }

    @MainActor
    @Test func balancedPreviewDoesNotPromoteGeneratedLayersToExportResolution() async throws {
        let text = TextTimelineItem(
            text: "Balanced",
            timelineStart: 0,
            duration: 1
        )
        let project = EditorProject(
            title: "Balanced Preview Proxy",
            renderSettings: RenderSettings(width: 2160, height: 3840, frameRate: 30),
            tracks: [
                TimelineTrack(
                    name: "Text",
                    kind: .text,
                    items: [.text(text)]
                )
            ]
        )
        let service = CompositionRenderService()

        let prepared = try await service.preparePreview(
            for: project,
            quality: .balanced,
            invalidation: [.previewFrame, .compositionTopology]
        )
        let instruction = try #require(
            prepared?.videoComposition?.instructions.first
                as? MotionaryVideoCompositionInstruction
        )

        #expect(instruction.renderSize == CGSize(width: 540, height: 960))
        #expect(abs(instruction.renderScale - 0.25) < 0.000_001)
        #expect(abs(instruction.vectorRenderScale - 0.375) < 0.000_001)
        #expect(instruction.qualityProfile == .balanced)
    }

    @MainActor
    private func makeViewModel(clip: TimelineClip? = nil) -> EditorViewModel {
        let tracks: [TimelineTrack]
        if let clip {
            tracks = [
                TimelineTrack(
                    name: clip.mediaType == .audio ? "Audio 1" : "Layer 1",
                    kind: clip.requiredTrackKind,
                    clips: [clip]
                )
            ]
        } else {
            tracks = []
        }
        return EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(
                editorProject: EditorProject(
                    title: "Preview Rebuilds",
                    tracks: tracks
                )
            )
        )
    }

    @MainActor
    private func makeGeneratedLayerViewModel() -> EditorViewModel {
        let shape = ShapeTimelineItem(
            name: "Preview Recovery",
            mediaID: MediaID(),
            shape: ClipShape(
                kind: .rectangle,
                color: .white,
                width: 64,
                height: 64
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        return EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(
                editorProject: EditorProject(
                    title: "Preview Recovery",
                    renderSettings: RenderSettings(width: 96, height: 128, frameRate: 30),
                    tracks: [
                        TimelineTrack(
                            name: "Shape",
                            kind: .shape,
                            items: [.shape(shape)]
                        )
                    ]
                )
            )
        )
    }

    private func makeSilentAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionary-live-audio-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 1
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let frameCount: AVAudioFrameCount = 44_100
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frameCount
        buffer.floatChannelData?[0].initialize(
            repeating: 0,
            count: Int(frameCount)
        )
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings
        )
        try file.write(from: buffer)
        return url
    }
}
