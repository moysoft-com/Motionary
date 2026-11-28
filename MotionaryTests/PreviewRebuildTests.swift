import AVFoundation
import Foundation
import CoreImage
import UIKit
import Testing

@testable import Motionary

/// Leaves seeks pending until the test delivers the AVFoundation callback.
private final class ControlledSeekPlayer: AVPlayer, @unchecked Sendable {
    private let callbackLock = NSLock()
    private var callbacks: [(@Sendable (Bool) -> Void)] = []
    private var requests: [(time: Double, tolerance: Double)] = []
    private(set) var playCalls = 0
    var reportedTime = CMTime.zero

    override func currentTime() -> CMTime { reportedTime }
    override func play() { playCalls += 1 }

    override func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completionHandler: (@Sendable (Bool) -> Void)? = nil
    ) {
        callbackLock.lock()
        requests.append((CMTimeGetSeconds(time), CMTimeGetSeconds(toleranceBefore)))
        if let completionHandler { callbacks.append(completionHandler) }
        callbackLock.unlock()
    }

    var seekRequests: [(time: Double, tolerance: Double)] {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return requests
    }

    var pendingSeekCount: Int {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return callbacks.count
    }

    func completeSeek(at index: Int, finished: Bool) {
        callbackLock.lock()
        let callback = callbacks[index]
        callbackLock.unlock()
        callback(finished)
    }
}

private final class FixedClockPlayer: AVPlayer, @unchecked Sendable {
    override func currentTime() -> CMTime { CMTime(value: 53, timescale: 60) }
}

private final class PlaybackStartProbe: AVPlayer, @unchecked Sendable {
    var playCalls = 0
    var immediateCalls = 0
    override func play() { playCalls += 1 }
    override func playImmediately(atRate rate: Float) { immediateCalls += 1 }
}

@Suite(.serialized)
struct PreviewRebuildTests {
    @Test(.timeLimit(.minutes(1)))
    func previewOpensBeforePendingAudioAndReceivesTheReadyCallback() async throws {
        let (completion, worker) = AsyncStream<Void>.makeStream()
        let (ready, callback) = AsyncStream<Void>.makeStream()
        let work = Task { () throws -> Int in
            for await _ in completion { return 1 }
            throw CancellationError()
        }
        defer {
            worker.finish()
            callback.finish()
            work.cancel()
        }
        let preparation = PreviewAudioPreparation(deadline: .now + .milliseconds(20), onReady: {
            callback.yield(())
            callback.finish()
        })
        #expect(try await preparation.wait(for: work) == nil)
        worker.yield(())
        var readiness = ready.makeAsyncIterator()
        #expect(await readiness.next() != nil)
    }

    @MainActor
    @Test func reopenedDenseReverseCurveBuildsAnEditablePreviewWithPCM() async throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let url = try makeSilentAudioFile()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: PreviewRetimedAudio.directory(for: url))
        }
        let clip = TimelineClip(name: "Dense remap", source: ClipSource(
            url: url, mediaType: .audio, originalDuration: 1),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 1))
        var project = model.project
        project.tracks.append(TimelineTrack(name: "Audio", kind: .audio, clips: [clip]))
        project.synchronizeMediaLibrary()
        var map = SpeedMap.constant
        var remap = try #require(TimeRemap(sourceDuration: 1, timelineDuration: 1))
        for index in 1..<40 {
            let time = Double(index) / 40
            remap.setSourceTime(index.isMultiple(of: 2) ? 0.025 : 0.975, at: time, tolerance: 0.000_001)
        }
        map.timeRemap = remap
        project.setSpeedMap(for: clip.id, speedMap: map)
        let reopened = try JSONDecoder().decode(EditorProject.self, from: JSONEncoder().encode(project))
        let render = model.renderService
        var items: [AVCompositionTrack] = []
        for _ in 0..<5 {
            let preview = try #require(try await render.preparePreview(for: reopened, quality: .balanced,
                invalidation: [.compositionTopology]))
            #expect(preview.videoComposition != nil)
            items = preview.composition.tracks(withMediaType: .audio)
            if !items.isEmpty { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        let audio = try #require(items.first)
        let segment = try #require(audio.segments.first(where: { !$0.isEmpty }))
        #expect(audio.segments.filter { !$0.isEmpty }.count == 1)
        #expect(segment.sourceURL?.deletingLastPathComponent() == PreviewRetimedAudio.directory(for: url))
        #expect(abs(audio.timeRange.duration.seconds - 1) < 0.001)
    }

    @MainActor
    @Test func playbackWaitsForAudioSessionBeforeStartingTheSharedClock() async {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let player = PlaybackStartProbe()
        model.player = player
        var ready: CheckedContinuation<Void, Never>?
        model.preparePlaybackAudio = {
            await withCheckedContinuation { ready = $0 }
        }
        model.startPreparedPlayback(player)
        for _ in 0..<100 where ready == nil { await Task.yield() }
        #expect(ready != nil)
        #expect(player.playCalls == 0)
        #expect(model.playbackState.isStartingPlayback)
        ready?.resume()
        for _ in 0..<100 where player.playCalls == 0 { await Task.yield() }
        #expect(player.playCalls == 1)
        #expect(player.immediateCalls == 0)
    }

    @MainActor
    @Test func cancellingPlaybackWhileAudioSessionStartsDoesNotPlayLater() async {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let player = PlaybackStartProbe()
        model.player = player
        var ready: CheckedContinuation<Void, Never>?
        model.preparePlaybackAudio = { await withCheckedContinuation { ready = $0 } }
        model.startPreparedPlayback(player)
        for _ in 0..<100 where ready == nil { await Task.yield() }
        #expect(ready != nil)
        model.togglePlayback()
        ready?.resume()
        for _ in 0..<10 { await Task.yield() }
        #expect(player.playCalls == 0)
        #expect(!model.isPlaying)
    }

    @MainActor
    @Test func topologyEditSupersedesPlaybackWaitingForTheAudioSession() async {
        let model = makeGeneratedLayerViewModel(duration: 4)
        defer { model.stop() }
        let previousPlayer = PlaybackStartProbe()
        model.player = previousPlayer
        var activate: CheckedContinuation<Void, Never>?
        model.preparePlaybackAudio = {
            await withCheckedContinuation { activate = $0 }
        }
        let oldStart = model.startPreparedPlayback(previousPlayer)
        for _ in 0..<100 where activate == nil { await Task.yield() }
        guard let activate else {
            Issue.record("Playback did not request audio-session activation.")
            return
        }

        model.schedulePreviewRebuild(delay: false, invalidation: [.compositionTopology, .audioMix])

        #expect(model.pendingPlaybackResumeAfterPreviewRebuild)
        model.preparePlaybackAudio = {}
        activate.resume()
        await oldStart.value
        #expect(previousPlayer.playCalls == 0)
        #expect(previousPlayer.immediateCalls == 0)
        await model.rebuildTask?.value
        #expect(model.player !== previousPlayer)
        #expect(model.isPlaying)
    }

    @MainActor
    @Test func pauseHandoffUsesTheActualPlayerPosition() {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        model.player = FixedClockPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        model.updateCurrentTime(0.75)
        model.isPlaying = true
        model.togglePlayback()
        #expect(!model.isPlaying)
        #expect(model.currentTime == 53 / 60.0)
    }

    @MainActor
    @Test func playSeeksToThePlayheadAfterTheScrollGestureHasEnded() async throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let player = ControlledSeekPlayer()
        model.player = player
        model.preparePlaybackAudio = {}
        let target = model.lastPlayableTime / 2
        model.updateCurrentTime(target)

        model.togglePlayback()
        for _ in 0..<100 where player.pendingSeekCount == 0 { await Task.yield() }
        let request = try #require(player.seekRequests.first)
        #expect(request.time == model.livePreviewPresentationTime(target))
        #expect(player.playCalls == 0)
        player.completeSeek(at: 0, finished: true)
        for _ in 0..<100 where player.playCalls == 0 { await Task.yield() }
        #expect(player.playCalls == 1)
    }

    @MainActor
    @Test func playbackWaitsForAnExactSeekAfterScrubbingEvenWhenThePlayerClockAlreadyMatches() async throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let player = ControlledSeekPlayer()
        model.player = player
        model.preparePlaybackAudio = {}
        let target = model.lastPlayableTime * 0.85

        model.beginScrub()
        model.endScrub(at: target)
        for _ in 0..<100 where player.pendingSeekCount == 0 { await Task.yield() }
        let scrubSeek = try #require(player.seekRequests.first)
        player.reportedTime = CMTime(seconds: scrubSeek.time, preferredTimescale: 600)
        player.completeSeek(at: 0, finished: true)
        for _ in 0..<100 where model.isScrubbing { await Task.yield() }
        try #require(!model.isScrubbing)

        model.togglePlayback()
        for _ in 0..<100 where player.pendingSeekCount < 2 { await Task.yield() }
        try #require(player.seekRequests.count == 2)
        #expect(player.seekRequests[1].time == scrubSeek.time)
        #expect(player.seekRequests[1].tolerance == 0)
        #expect(player.playCalls == 0)
        player.completeSeek(at: 1, finished: true)
        for _ in 0..<100 where player.playCalls == 0 { await Task.yield() }
        #expect(player.playCalls == 1)
        #expect(!model.playbackNeedsSeekAfterNavigation)
    }

    @MainActor
    @Test func playbackSeeksEvenWhenThePausedClockMatchesAfterAMixUpdate() async throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let player = ControlledSeekPlayer()
        model.player = player
        model.preparePlaybackAudio = {}
        model.playbackNeedsSeekAfterMixUpdate = true

        model.togglePlayback()
        for _ in 0..<100 where player.pendingSeekCount == 0 { await Task.yield() }
        let request = try #require(player.seekRequests.first)
        #expect(request.time == 0)
        #expect(request.tolerance == 0)
        #expect(player.playCalls == 0)

        player.completeSeek(at: 0, finished: true)
        for _ in 0..<100 where player.playCalls == 0 { await Task.yield() }
        #expect(player.playCalls == 1)
        #expect(!model.playbackNeedsSeekAfterMixUpdate)
    }

    @MainActor
    @Test(arguments: [false, true])
    func aStructuralEditInstallsItsGraphDuringTheNextScrub(releaseBeforeBuild: Bool) async throws {
        let shape = ShapeTimelineItem(name: "Scrub after cut", mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle, color: .white, width: 64, height: 64),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 4))
        let track = TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])
        let project = EditorProject(title: "Cut then scrub",
            renderSettings: RenderSettings(width: 96, height: 128), tracks: [track])
        let model = EditorViewModel(projectID: UUID(), projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project))
        defer { model.stop() }
        model.start()
        await model.rebuildTask?.value
        let originalItem = model.player?.currentItem
        model.selectTimelineItem(shape.id, trackID: track.id)
        model.updateCurrentTime(2)
        let revision = model.renderService.livePreviewState.snapshot().revision
        _ = try #require(model.splitSelectedTimelineItem())
        #expect(model.renderService.livePreviewState.snapshot().revision > revision)
        model.beginScrub()
        model.updateScrub(to: 1.25)
        if releaseBeforeBuild { model.endScrub(at: 1.25) }
        let rebuild = try #require(model.rebuildTask, "Scrubbing must retain required topology work")
        await rebuild.value
        #expect(model.player?.currentItem !== originalItem)
        #expect(!model.pendingPreviewInvalidation.contains(.compositionTopology))
        if !releaseBeforeBuild { #expect(model.isScrubbing) }
        let instructions = model.player?.currentItem?.videoComposition?.instructions
        let instruction = try #require(instructions?.first as? MotionaryVideoCompositionInstruction)
        #expect(instruction.clips.count == 2)
        model.endScrub(at: 1.25)
        for _ in 0..<1000 where model.isScrubbing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.isScrubbing)
        #expect(model.currentTime == 1.25)
        #expect(model.errorMessage == nil)
    }

    @MainActor
    @Test func adjustmentTargetChangesInvalidateAndRefreshPreview() async throws {
        let shape = ShapeTimelineItem(
            name: "Shape", mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle, color: .white, width: 64, height: 64),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let shapeTrack = TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])
        let adjustment = AdjustmentTimelineItem(timelineStart: 0, duration: 2)
        let project = EditorProject(
            title: "Adjustment targets",
            renderSettings: RenderSettings(width: 96, height: 128, frameRate: 30),
            tracks: [TimelineTrack(name: "Adjustment", kind: .visual, items: [.adjustment(adjustment)]), shapeTrack]
        )
        var updated = project
        var changed = adjustment
        changed.targets = AdjustmentLayerTargets(mode: .selected, trackIDs: [shapeTrack.id])
        updated.tracks[0].items[0] = .adjustment(changed)
        let invalidation = updated.renderInvalidation(comparedTo: project)
        #expect(invalidation.contains(.previewFrame))
        #expect(!invalidation.contains(.compositionTopology))

        let service = CompositionRenderService()
        _ = try await service.preparePreview(for: project, quality: .balanced,
            invalidation: [.previewFrame, .compositionTopology, .audioMix])
        let prepared = try #require(try await service.preparePreview(
            for: updated, quality: .balanced, invalidation: invalidation
        ))
        let instruction = try #require(prepared.videoComposition?.instructions.first as? MotionaryVideoCompositionInstruction)
        let descriptor = try #require(instruction.clips.first { $0.clipID == adjustment.id })
        #expect(descriptor.adjustmentTargets == changed.targets)
        #expect(!prepared.topologyWasRebuilt)
    }

    @MainActor
    @Test func seekingAfterSplitSurvivesTheScheduledPreviewRebuild() async throws {
        let shape = ShapeTimelineItem(
            name: "Split and seek", mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle, color: .white, width: 64, height: 64),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 4)
        )
        let track = TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])
        let project = EditorProject(title: "Split and seek",
                                    renderSettings: RenderSettings(width: 96, height: 128, frameRate: 30),
                                    tracks: [track])
        let model = EditorViewModel(projectID: UUID(), projectStore: ProjectStore(),
                                    initialContent: ProjectContent(editorProject: project))
        defer { model.stop() }
        model.selectTimelineItem(shape.id, trackID: track.id)
        model.seek(to: 1)
        _ = try #require(model.splitSelectedTimelineItem())
        let rebuild = try #require(model.rebuildTask)
        model.seek(to: 2.5)
        await rebuild.value
        #expect(abs(model.currentTime - 2.5) < 0.001)
        #expect(model.player != nil)
    }

    @MainActor
    @Test func returningInteractiveEditToItsStartKeepsTheLiveFrameDuringHandoff() throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let itemID = try #require(model.project.tracks.first?.items.first?.id)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        model.livePreviewPresentation.setFrame(frame, at: 0)
        model.interactiveEditSnapshot = model.project
        model.pendingLiveVisualOverrideItemIDs.insert(itemID)
        model.finishInteractiveEdit()
        #expect(model.livePreviewPresentation.frame === frame)
        #expect(model.rebuildTask != nil)
        #expect(model.pendingLiveVisualOverrideItemIDs.contains(itemID))
    }

    @MainActor
    @Test func finishingPreviewRebuildKeepsTheDisplayedFrameUntilReplacement() async throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        await model.rebuildPreview(invalidation: [.previewFrame, .compositionTopology, .audioMix],
                                   generation: model.previewGeneration)
        let item = try #require(model.player?.currentItem)
        let controlled = ControlledSeekPlayer()
        controlled.replaceCurrentItem(with: AVPlayerItem(asset: item.asset))
        if let observer = model.timeObserver {
            model.player?.removeTimeObserver(observer)
            model.timeObserver = nil
        }
        model.player = controlled
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let held = try #require(buffer)
        model.livePreviewPresentation.setFrame(held, at: 0)
        let rebuild = Task { @MainActor in
            await model.rebuildPreview(seekTo: 0.2, invalidation: [.previewFrame], generation: model.previewGeneration)
        }
        for _ in 0..<500 where controlled.pendingSeekCount < 1 {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard controlled.pendingSeekCount > 0 else {
            rebuild.cancel()
            Issue.record("Preview rebuild did not start its seek")
            return
        }
        controlled.completeSeek(at: 0, finished: true)
        await rebuild.value
        #expect(model.livePreviewPresentation.frame === held)
        #expect(model.pendingLivePreviewFrameRefresh || model.livePreviewFrameRefreshInFlight)
    }

    @MainActor
    @Test func laterSeekWinsWhilePreviewRebuildSeekIsInFlight() async throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        model.previewQuality = .balanced
        await model.rebuildPreview(invalidation: [.previewFrame, .compositionTopology, .audioMix],
                                   generation: model.previewGeneration)
        let originalItem = try #require(model.player?.currentItem)
        let controlled = ControlledSeekPlayer()
        controlled.replaceCurrentItem(with: AVPlayerItem(asset: originalItem.asset))
        if let observer = model.timeObserver {
            model.player?.removeTimeObserver(observer)
            model.timeObserver = nil
        }
        model.player = controlled
        let generation = model.previewGeneration
        let rebuild = Task { @MainActor in
            await model.rebuildPreview(seekTo: 0.2, invalidation: [.previewFrame], generation: generation)
        }
        for _ in 0..<500 where controlled.pendingSeekCount < 1 {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard controlled.pendingSeekCount >= 1 else {
            rebuild.cancel()
            Issue.record("Preview rebuild did not start its seek")
            return
        }
        model.seek(to: 0.7)
        for _ in 0..<500 where controlled.pendingSeekCount < 2 {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard controlled.pendingSeekCount >= 2 else {
            rebuild.cancel()
            controlled.completeSeek(at: 0, finished: false)
            Issue.record("The newer seek did not reach the player")
            return
        }
        controlled.completeSeek(at: 1, finished: true)
        controlled.completeSeek(at: 0, finished: true)
        await rebuild.value
        #expect(abs(model.currentTime - 0.7) < 0.001)
    }

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

    @MainActor
    @Test func videoClockAndDependenciesCoverLayerEndsGapsAndAudioTail() async throws {
        // Keep fixture media on a distinct file, as real project imports are,
        // so source decoding and private clock decoding do not alias one asset.
        let clockFixture = try await MediaConversionHelper.blankVideoClockURL(duration: 1, frameRate: 30)
        let videoURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try FileManager.default.copyItem(at: clockFixture, to: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let audioURL = try makeSilentAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let first = TimelineClip(
            name: "First video", source: ClipSource(url: videoURL, mediaType: .video, originalDuration: 1),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 0.2)
        )
        let second = TimelineClip(
            name: "Later video", source: ClipSource(url: videoURL, mediaType: .video, originalDuration: 1),
            timelineStart: 0.4, sourceRange: TimeRangeValue(start: 0, duration: 0.2)
        )
        let audio = TimelineClip(
            name: "Longer audio", source: ClipSource(url: audioURL, mediaType: .audio, originalDuration: 1),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        let project = EditorProject(
            title: "Source boundaries",
            renderSettings: RenderSettings(width: 96, height: 128, frameRate: 30),
            tracks: [TimelineTrack(name: "Video", kind: .visual, clips: [first, second]),
                     TimelineTrack(name: "Audio", kind: .audio, clips: [audio])]
        )
        let rendered = try await CompositionRenderService().makeComposition(for: project)
        let clock = try #require(rendered.videoClockTrackID)
        let composition = try #require(rendered.videoComposition)
        #expect(composition.sourceTrackIDForFrameTiming == clock)
        let clockTrack = try #require(rendered.composition.track(withTrackID: clock))
        let clockRange = try await clockTrack.load(.timeRange)
        #expect(abs(CMTimeGetSeconds(clockRange.end) - 1) < 0.001)
        let instructions = try composition.instructions.map {
            try #require($0 as? MotionaryVideoCompositionInstruction)
        }
        #expect(CMTimeGetSeconds(try #require(instructions.last).timeRange.end) == 1)
        for (left, right) in zip(instructions, instructions.dropFirst()) {
            #expect(CMTimeCompare(left.timeRange.end, right.timeRange.start) == 0)
        }
        for time in [0.1, 0.3, 0.5, 0.8] {
            let instruction = try #require(instructions.first {
                CMTimeRangeContainsTime($0.timeRange, time: CMTime(seconds: time, preferredTimescale: 600))
            })
            let active = instruction.activeClips(at: time)
            let required = Set((instruction.requiredSourceTrackIDs ?? []).compactMap { ($0 as? NSNumber)?.int32Value })
            let expected = Set(active.map(\.trackID) + [clock])
            #expect(required == expected)
            #expect(active.count == ((time == 0.1 || time == 0.5) ? 1 : 0))
        }
        // Exercise the real compositor after a source ends and through the trailing audio interval.
        let probe = PlayerFrameProbe(asset: rendered.composition, videoComposition: composition)
        for time in [0.1, 0.3, 0.5, 0.8] {
            let image = try await probe.image(at: CMTime(seconds: time, preferredTimescale: 600))
            #expect(image.extent.width == 96)
            #expect(image.extent.height == 128)
        }
    }

    @MainActor
    @Test func endedImageRevealsUnderlyingShapeThenAudioTailBackground() async throws {
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        try #require(image.pngData()).write(to: imageURL)
        let audioURL = try makeSilentAudioFile()
        defer {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: audioURL)
        }
        let still = TimelineClip(
            name: "Short image", source: ClipSource(url: imageURL, mediaType: .image, originalDuration: 1),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 0.2)
        )
        let shape = ShapeTimelineItem(
            name: "Underlying green", mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle, color: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1),
                             width: 96, height: 128),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 0.6)
        )
        let audio = TimelineClip(
            name: "Audio tail", source: ClipSource(url: audioURL, mediaType: .audio, originalDuration: 1),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        let project = EditorProject(
            title: "Image boundary",
            renderSettings: RenderSettings(width: 96, height: 128, frameRate: 30,
                                           backgroundColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)),
            tracks: [TimelineTrack(name: "Image", kind: .visual, clips: [still]),
                     TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)]),
                     TimelineTrack(name: "Audio", kind: .audio, clips: [audio])]
        )
        let prepared = try #require(try await CompositionRenderService().preparePreview(
            for: project, quality: .balanced, invalidation: [.previewFrame, .compositionTopology, .audioMix]
        ))
        let generator = AVAssetImageGenerator(asset: prepared.composition)
        generator.videoComposition = prepared.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let context = CIContext()
        for (time, expected) in [(0.1, [255, 255, 255]), (0.3, [0, 255, 0]), (0.8, [0, 0, 0])] {
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(CIImage(cgImage: frame), toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 48, y: 64, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            for channel in 0..<3 {
                #expect(abs(Int(pixel[channel]) - expected[channel]) < 10)
            }
        }
        let item = AVPlayerItem(asset: prepared.composition)
        item.videoComposition = prepared.videoComposition
        item.audioMix = prepared.audioMix
        let player = AVPlayer(playerItem: item)
        let observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { _ in }
        defer { player.pause(); player.removeTimeObserver(observer) }
        player.play()
        for _ in 0..<200 {
            if CMTimeGetSeconds(player.currentTime()) >= 0.8 || item.status == .failed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(item.status == .readyToPlay)
        #expect(CMTimeGetSeconds(player.currentTime()) >= 0.8)
    }

    @MainActor
    @Test func supersededRebuildRetainsAudioAndTopologyInvalidations() {
        let viewModel = makeGeneratedLayerViewModel()
        defer { viewModel.stop() }
        viewModel.schedulePreviewRebuild(delay: true, invalidation: [.audioMix, .compositionTopology])
        let oldTask = viewModel.rebuildTask
        viewModel.schedulePreviewRebuild(delay: true, invalidation: [.previewFrame])
        #expect(oldTask?.isCancelled == true)
        #expect(viewModel.pendingPreviewInvalidation.contains(.audioMix))
        #expect(viewModel.pendingPreviewInvalidation.contains(.compositionTopology))
        #expect(viewModel.pendingPreviewInvalidation.contains(.previewFrame))
    }

    @MainActor
    @Test func compositionReplacementRejectsNotificationsFromPreviousGraphOnSameItem() async throws {
        let viewModel = makeGeneratedLayerViewModel()
        defer { viewModel.stop() }
        viewModel.previewQuality = .balanced
        await viewModel.rebuildPreview(invalidation: [.previewFrame, .compositionTopology, .audioMix],
                                       generation: viewModel.previewGeneration)
        let oldSession = viewModel.previewRenderSessionID
        let item = try #require(viewModel.player?.currentItem)
        await viewModel.rebuildPreview(invalidation: [.previewFrame], generation: viewModel.previewGeneration)
        #expect(viewModel.player?.currentItem === item)
        #expect(viewModel.previewRenderSessionID != oldSession)
        let recoveryCount = viewModel.previewRecoveryAttemptCount
        NotificationCenter.default.post(name: .motionaryVideoCompositorPersistentFailure,
                                        object: nil, userInfo: ["renderSessionID": oldSession])
        for _ in 0..<5 { await Task.yield() }
        #expect(viewModel.previewRecoveryAttemptCount == recoveryCount)
    }

    @MainActor
    @Test func compositorNotificationsDoNotWaitForMainThread() async {
        let viewModel = makeGeneratedLayerViewModel()
        defer { viewModel.stop() }
        let item = AVPlayerItem(asset: AVMutableComposition())
        viewModel.replacePreviewPlayer(with: item)
        viewModel.installPreviewItemHealthObservers(for: item)
        let session = viewModel.previewRenderSessionID

        for name in [Notification.Name.motionaryVideoCompositorRenderedFrame,
                     .motionaryVideoCompositorPersistentFailure] {
            let posted = DispatchSemaphore(value: 0)
            // Exercise failure delivery without starting an unrelated recovery.
            let notificationSession = name == .motionaryVideoCompositorRenderedFrame ? session : UUID()
            DispatchQueue.global().async {
                NotificationCenter.default.post(
                    name: name, object: nil, userInfo: ["renderSessionID": notificationSession]
                )
                posted.signal()
            }
            // Model Core Animation holding the main thread while a GPU callback
            // posts. Posting must return before the main actor can run UI work.
            func waitForPost() -> DispatchTimeoutResult {
                posted.wait(timeout: .now() + 1)
            }
            let result = waitForPost()
            #expect(result == .success)
        }
        for _ in 0..<100 {
            if viewModel.lastPreviewRenderedFrameAt > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.lastPreviewRenderedFrameAt > 0)
    }

    @MainActor
    @Test func staleRenderedFrameDoesNotMarkCurrentSessionHealthy() async {
        let viewModel = makeGeneratedLayerViewModel()
        defer { viewModel.stop() }
        let item = AVPlayerItem(asset: AVMutableComposition())
        viewModel.replacePreviewPlayer(with: item)
        viewModel.installPreviewItemHealthObservers(for: item)
        NotificationCenter.default.post(name: .motionaryVideoCompositorRenderedFrame,
                                        object: nil, userInfo: ["renderSessionID": UUID()])
        for _ in 0..<5 { await Task.yield() }
        #expect(viewModel.lastPreviewRenderedFrameAt == 0)
        NotificationCenter.default.post(name: .motionaryVideoCompositorRenderedFrame,
                                        object: nil, userInfo: ["renderSessionID": viewModel.previewRenderSessionID])
        for _ in 0..<5 { await Task.yield() }
        #expect(viewModel.lastPreviewRenderedFrameAt > 0)
    }

    @MainActor
    @Test func presentationClockMatchesSeekPrecision() {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let actual = model.livePreviewPresentationTime(0.517)
        #expect(abs(actual - 0.5166666667) < 0.00001)
    }

    @MainActor
    @Test func sustainedDistantScrubJumpsKeepOnlyTheLatestPositionBehindOneSeek() async throws {
        let model = makeGeneratedLayerViewModel(duration: 12)
        defer { model.stop() }
        let player = ControlledSeekPlayer()
        model.player = player
        model.beginScrub()
        model.updateScrub(to: 0.2)
        for _ in 0..<100 where player.pendingSeekCount < 1 {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(player.pendingSeekCount == 1)

        for index in 0..<2_000 {
            model.updateScrub(to: index.isMultiple(of: 2) ? 10.5 : 1.5)
        }
        model.updateScrub(to: 9.5)
        #expect(player.pendingSeekCount == 1)
        player.completeSeek(at: 0, finished: true)
        for _ in 0..<100 where player.pendingSeekCount < 2 {
            try await Task.sleep(for: .milliseconds(2))
        }
        let requests = player.seekRequests
        if requests.count == 2 { player.completeSeek(at: 1, finished: true) }
        #expect(requests.map(\.time) == [0.2, 9.5])
    }

    @MainActor
    @Test func scrubbingCoalescesDecoderWorkAndFinishesExactly() async throws {
        let viewModel = makeGeneratedLayerViewModel()
        defer { viewModel.stop() }
        let player = ControlledSeekPlayer()
        viewModel.player = player
        viewModel.beginScrub()
        // Expensive decoding keeps bounded pacing while new inputs replace
        // the single pending destination instead of queuing stale seeks.
        viewModel.lastScrubUIUpdate = CFAbsoluteTimeGetCurrent()
        viewModel.updateScrub(to: 0.1)
        for _ in 0..<100 where player.pendingSeekCount < 1 { try await Task.sleep(for: .milliseconds(2)) }
        guard player.pendingSeekCount == 1 else { Issue.record("First scrub seek missing"); return }
        viewModel.updateScrub(to: 0.2)
        viewModel.updateScrub(to: 0.7)
        viewModel.updateScrub(to: 0.8)
        #expect(player.pendingSeekCount == 1)
        player.completeSeek(at: 0, finished: true)
        for _ in 0..<100 where player.pendingSeekCount < 2 { try await Task.sleep(for: .milliseconds(2)) }
        guard player.pendingSeekCount == 2 else { Issue.record("Latest scrub seek was delayed"); return }
        #expect(player.seekRequests.map(\.time) == [0.1, 0.8])
        #expect(player.seekRequests.allSatisfy { $0.tolerance == 0 })
        viewModel.updateScrub(to: 0.8)
        #expect(viewModel.pendingScrubSeekTime == nil)
        player.completeSeek(at: 1, finished: true)
        for _ in 0..<100 where viewModel.isScrubSeekInFlight { await Task.yield() }
        viewModel.updateScrub(to: 0.8)
        #expect(player.pendingSeekCount == 2)
        viewModel.endScrub(at: 0.9)
        for _ in 0..<100 where player.pendingSeekCount < 3 { await Task.yield() }
        guard player.pendingSeekCount == 3 else { Issue.record("Final exact seek missing"); return }
        #expect(player.seekRequests[2].time == 0.9)
        #expect(player.seekRequests[2].tolerance == 0)
        player.completeSeek(at: 2, finished: true)
        for _ in 0..<100 where viewModel.isScrubbing { await Task.yield() }
        #expect(!viewModel.isScrubbing)
        #expect(viewModel.currentTime == 0.9)
    }

    @MainActor
    @Test func scrubbingHoldsACompletedFrameAcrossPlayerHandoffs() throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        model.player = ControlledSeekPlayer()
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess)
        let frame = try #require(pixelBuffer)
        let state = model.renderService.livePreviewState
        state.cacheFrame(frame, at: 0, sessionID: model.previewRenderSessionID,
                         revision: state.snapshot().revision)
        model.beginScrub()
        #expect(model.livePreviewPresentation.frame === frame)
        model.finishScrub(at: 0, generation: model.scrubSessionGeneration)
        #expect(!model.isScrubbing)
        #expect(model.livePreviewPresentation.frame === frame)
    }

    @MainActor
    @Test func releasingOnACachedScrubFrameRestoresFullQualityAtTheSameTime() async throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let player = ControlledSeekPlayer()
        let prepared = try #require(try await model.renderService.preparePreview(
            for: model.project, quality: .balanced,
            invalidation: [.previewFrame, .compositionTopology], renderSessionID: model.previewRenderSessionID
        ))
        let item = AVPlayerItem(asset: prepared.composition)
        item.videoComposition = prepared.videoComposition
        try #require(item.videoComposition != nil)
        player.replaceCurrentItem(with: item)
        model.player = player
        model.beginScrub()

        var scrubBuffer: CVPixelBuffer?
        var fullBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &scrubBuffer) == kCVReturnSuccess)
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &fullBuffer) == kCVReturnSuccess)
        let scrubFrame = try #require(scrubBuffer)
        let fullFrame = try #require(fullBuffer)
        let state = model.renderService.livePreviewState
        let revision = state.snapshot().revision
        let target = 0.5
        state.cacheFrame(scrubFrame, at: target, sessionID: model.previewRenderSessionID,
                         revision: revision, isScrubFrame: true)
        model.updateScrub(to: target)
        #expect(model.livePreviewPresentation.frame === scrubFrame)

        state.installPausedFrameRenderer { time, sessionID, _, completion in
            #expect(time == target)
            #expect(!state.snapshot().isScrubbing)
            #expect(!state.snapshot().usesInteractiveQuality)
            state.cacheFrame(fullFrame, at: time, sessionID: sessionID, revision: revision)
            completion(fullFrame)
            return true
        }
        defer { state.clearPausedFrameRenderer() }
        model.endScrub(at: target)
        for _ in 0..<100 where player.pendingSeekCount == 0 { await Task.yield() }
        try #require(player.pendingSeekCount == 1)
        player.completeSeek(at: 0, finished: true)
        for _ in 0..<100 where model.livePreviewPresentation.frame !== fullFrame { await Task.yield() }
        #expect(!model.isScrubbing)
        #expect(model.livePreviewPresentation.frame === fullFrame)
        #expect(model.livePreviewPresentation.frameTime == target)
        #expect(player.pendingSeekCount == 1)
    }

    @MainActor
    @Test func frozenScrubKeepsThePreviewWhileTheTimelineMovesAndSeeksOnRelease() async throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let player = ControlledSeekPlayer()
        model.player = player
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        let state = model.renderService.livePreviewState
        for time in [0.0, 0.5] {
            state.cacheFrame(frame, at: time, sessionID: model.previewRenderSessionID,
                             revision: state.snapshot().revision)
        }
        model.configureScreenRecordingPreview(.init(freezesScrubPreview: true))
        model.beginScrub()
        model.updateScrub(to: 0.5)
        #expect(model.currentTime == 0.5)
        #expect(model.livePreviewPresentation.frameTime == 0)
        #expect(player.pendingSeekCount == 0)

        model.endScrub(at: 0.5)
        for _ in 0..<100 where player.pendingSeekCount == 0 { await Task.yield() }
        try #require(player.pendingSeekCount == 1)
        #expect(player.seekRequests.first?.time == 0.5)
        #expect(player.seekRequests.first?.tolerance == 0)
        player.completeSeek(at: 0, finished: true)
        for _ in 0..<100 where model.isScrubbing { await Task.yield() }
        #expect(model.livePreviewPresentation.frameTime == 0.5)
    }

    @MainActor
    @Test func recordingScrubLimitAlsoPacesCachedFrames() async throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let player = ControlledSeekPlayer()
        model.player = player
        model.configureScreenRecordingPreview(.init(scrubFrameRateLimit: 30))
        model.beginScrub()
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        let state = model.renderService.livePreviewState
        for time in [0.5, 0.8] {
            state.cacheFrame(frame, at: time, sessionID: model.previewRenderSessionID,
                             revision: state.snapshot().revision)
        }

        model.updateScrub(to: 0.5)
        #expect(model.livePreviewPresentation.frameTime == 0.5)
        model.lastScrubUIUpdate = CFAbsoluteTimeGetCurrent()
        model.updateScrub(to: 0.8)
        #expect(model.currentTime == 0.8)
        #expect(model.livePreviewPresentation.frameTime == 0.5)
        for _ in 0..<100 where model.livePreviewPresentation.frameTime != 0.8 {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(model.livePreviewPresentation.frameTime == 0.8)
        #expect(player.pendingSeekCount == 0)
    }

    @MainActor
    @Test func cachedScrubFrameDisplaysImmediatelyWithoutDecoderWork() throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let player = ControlledSeekPlayer()
        model.player = player
        model.beginScrub()
        var frame: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 96, 96, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &frame) == kCVReturnSuccess)
        let buffer = try #require(frame)
        model.renderService.livePreviewState.cacheFrame(buffer, at: 0.5,
            sessionID: model.previewRenderSessionID,
            revision: model.renderService.livePreviewState.snapshot().revision)
        model.updateScrub(to: 0.5)
        #expect(model.livePreviewPresentation.frame === buffer)
        #expect(player.pendingSeekCount == 0)
        #expect(!model.isScrubSeekInFlight)
        #expect(model.pendingScrubSeekTime == nil)
    }

    @MainActor
    @Test func generatedScrubRequestsCoalesceOnGPUWithoutDecoderSeeks() async throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let player = ControlledSeekPlayer()
        model.player = player
        model.beginScrub()
        var requests: [Double] = []
        var completions: [(CVPixelBuffer?) -> Void] = []
        model.renderService.livePreviewState.installPausedFrameRenderer { time, _, _, completion in
            requests.append(time)
            completions.append(completion)
            return true
        }
        model.updateScrub(to: 0.1)
        model.updateScrub(to: 0.3)
        model.updateScrub(to: 0.8)
        #expect(requests == [0.1])
        #expect(player.pendingSeekCount == 0)
        var frame: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 96, 96, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &frame) == kCVReturnSuccess)
        let buffer = try #require(frame)
        model.renderService.livePreviewState.cacheFrame(buffer, at: 0.1,
            sessionID: model.previewRenderSessionID,
            revision: model.renderService.livePreviewState.snapshot().revision)
        completions[0](buffer)
        for _ in 0..<100 where requests.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(requests == [0.1, 0.8])
        #expect(player.pendingSeekCount == 0)
        #expect(model.livePreviewPresentation.frameTime == 0.1)
        if completions.count == 2 {
            model.renderService.livePreviewState.cacheFrame(buffer, at: 0.8,
                sessionID: model.previewRenderSessionID,
                revision: model.renderService.livePreviewState.snapshot().revision)
            completions[1](buffer)
            for _ in 0..<100 where model.livePreviewPresentation.frameTime != 0.8 { await Task.yield() }
            #expect(model.livePreviewPresentation.frame === buffer)
            #expect(model.livePreviewPresentation.frameTime == 0.8)
        }
    }

    @MainActor
    @Test func scrubCacheHitDoesNotQueueSpeculativeRendering() async throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        model.player = ControlledSeekPlayer()
        model.beginScrub()
        var cancellations: [@Sendable () -> Bool] = []
        var completions: [(CVPixelBuffer?) -> Void] = []
        model.renderService.livePreviewState.installPausedFrameRenderer { _, _, isCancelled, completion in
            cancellations.append(isCancelled)
            completions.append(completion)
            return true
        }
        var frame: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &frame) == kCVReturnSuccess)
        model.renderService.livePreviewState.cacheFrame(try #require(frame), at: 0.5,
            sessionID: model.previewRenderSessionID,
            revision: model.renderService.livePreviewState.snapshot().revision)
        model.updateScrub(to: 0.5)
        try await Task.sleep(for: .milliseconds(50))
        #expect(cancellations.isEmpty)

        model.updateScrub(to: 0.8)
        for _ in 0..<100 where cancellations.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(cancellations.count == 1)
        #expect(cancellations.last?() == false)
        for completion in completions { completion(nil) }
    }

    @MainActor
    @Test func lateScrubFramesAdvanceTowardTheTargetWithoutOvershooting() throws {
        let model = makeGeneratedLayerViewModel(duration: 10)
        defer { model.stop() }
        model.updateCurrentTime(8)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        model.livePreviewPresentation.setFrame(frame, at: 0)
        model.presentScrubFrame(frame, at: 2)
        model.presentScrubFrame(frame, at: 4)
        #expect(model.livePreviewPresentation.frameTime == 4)
        model.presentScrubFrame(frame, at: 3)
        model.presentScrubFrame(frame, at: 8.1)
        #expect(model.livePreviewPresentation.frameTime == 4)

        model.updateCurrentTime(1)
        model.presentScrubFrame(frame, at: 6)
        #expect(model.livePreviewPresentation.frameTime == 4)
        model.presentScrubFrame(frame, at: 2)
        #expect(model.livePreviewPresentation.frameTime == 2)
        model.presentScrubFrame(frame, at: 1)
        #expect(model.livePreviewPresentation.frameTime == 1)
    }

    @MainActor
    @Test func forwardEditPointIsDisabledAtTheLastPlayableFrame() {
        let model = makeGeneratedLayerViewModel(duration: 4)
        defer { model.stop() }
        model.updateCurrentTime(model.lastPlayableTime)
        let revision = model.playbackState.timelineNavigationRevision
        #expect(!model.canNavigateForward)
        model.navigateForward()
        #expect(model.currentTime == model.lastPlayableTime)
        #expect(model.playbackState.timelineNavigationRevision == revision)

        #expect(model.canNavigateBackward)
        model.navigateBackward()
        #expect(model.currentTime == 0)
        #expect(model.playbackState.timelineNavigationRevision == revision + 1)
    }

    @MainActor
    @Test func navigatingBeyondLastFrameSupersedesScrubAndCanSeekBack() async throws {
        // The short partial frame rounds down to the exclusive composition end.
        let model = makeGeneratedLayerViewModel(duration: 120.0005)
        defer { model.stop() }
        let player = ControlledSeekPlayer()
        model.player = player
        model.beginScrub()
        model.endScrub(at: 119.5)
        for _ in 0..<100 where player.pendingSeekCount < 1 { await Task.yield() }
        try #require(player.pendingSeekCount == 1)

        model.seek(to: 121)
        for _ in 0..<100 where player.pendingSeekCount < 2 { await Task.yield() }
        try #require(player.pendingSeekCount == 2)
        #expect(player.seekRequests[1].time < model.livePreviewPresentationTime(model.duration))
        player.completeSeek(at: 1, finished: true)
        player.completeSeek(at: 0, finished: false)
        #expect(!model.isScrubbing)
        #expect(!model.scrubIsFinishing)
        #expect(model.currentTime == model.duration)

        model.seek(to: 119)
        for _ in 0..<100 where player.pendingSeekCount < 3 { await Task.yield() }
        try #require(player.pendingSeekCount == 3)
        player.completeSeek(at: 2, finished: true)
        #expect(player.seekRequests[2].time == 119)
        #expect(model.currentTime == 119)
        #expect(model.previewRecoveryAttemptCount == 0)
    }

    @MainActor
    @Test func scrubEndingBeforeQueuedSeekStartsCannotOverrideFinalPosition() async {
        let viewModel = makeGeneratedLayerViewModel()
        defer { viewModel.stop() }
        let player = ControlledSeekPlayer()
        viewModel.player = player
        viewModel.beginScrub()
        viewModel.updateScrub(to: 0.1)
        viewModel.endScrub(at: 0.9)
        for _ in 0..<100 where player.pendingSeekCount < 1 { await Task.yield() }
        guard player.pendingSeekCount == 1 else { Issue.record("Final seek missing"); return }
        #expect(player.seekRequests[0].time == 0.9)
        #expect(player.seekRequests[0].tolerance == 0)
        player.completeSeek(at: 0, finished: true)
        for _ in 0..<100 where viewModel.isScrubbing { await Task.yield() }
        #expect(!viewModel.isScrubbing)
        #expect(viewModel.currentTime == 0.9)
    }

    @MainActor
    @Test func previousScrubFinalSeekCannotOverrideANewGesture() async {
        let viewModel = makeGeneratedLayerViewModel()
        defer { viewModel.stop() }
        let player = ControlledSeekPlayer()
        viewModel.player = player
        viewModel.beginScrub()
        viewModel.endScrub(at: 0.9)
        // Complete one session and start another before either queued task
        // runs. Only the new session may send a seek to AVPlayer.
        viewModel.beginScrub()
        viewModel.updateScrub(to: 0.2)
        for _ in 0..<100 where player.pendingSeekCount < 1 { await Task.yield() }
        guard player.pendingSeekCount == 1 else { Issue.record("New scrub seek missing"); return }
        #expect(player.seekRequests[0].time == 0.2)
        player.completeSeek(at: 0, finished: true)
        for _ in 0..<100 where viewModel.isScrubSeekInFlight { await Task.yield() }
        #expect(viewModel.currentTime == 0.2)
        #expect(viewModel.isScrubbing)
    }

    @MainActor
    @Test func realPlayerScrubbingUsesDecoderFriendlyTolerance() async throws {
        let url = try await MediaConversionHelper.blankVideoClockURL(duration: 2, frameRate: 30)
        let clip = TimelineClip(
            name: "Decoded scrub", source: ClipSource(url: url, mediaType: .video, originalDuration: 2,
                                                      naturalSize: CGSizeValue(width: 64, height: 64)),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let viewModel = makeViewModel(clip: clip)
        defer { viewModel.stop() }
        let prepared = try #require(try await viewModel.renderService.preparePreview(
            for: viewModel.project, quality: .interactive,
            invalidation: [.previewFrame, .compositionTopology], renderSessionID: viewModel.previewRenderSessionID
        ))
        let item = AVPlayerItem(asset: prepared.composition)
        item.videoComposition = prepared.videoComposition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        viewModel.player = AVPlayer(playerItem: item)
        viewModel.beginScrub()
        var durations: [Double] = []
        for index in 0..<12 {
            let target = index.isMultiple(of: 2) ? 0.1 + Double(index) * 0.03 : 1.5 - Double(index) * 0.03
            let start = ProcessInfo.processInfo.systemUptime
            viewModel.updateScrub(to: target)
            for _ in 0..<1000 {
                if !viewModel.isScrubSeekInFlight && viewModel.scrubSeekTask == nil { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(!viewModel.isScrubSeekInFlight)
            #expect(viewModel.scrubSeekTask == nil)
            #expect(viewModel.previewRecoveryAttemptCount == 0)
            durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        #expect(item.status != .failed)
        #expect(viewModel.currentTime > 1)
        Attachment.record("Real AVPlayer / H.264 clock / 12 alternating scrub targets, completion ms: \(durations)",
                          named: "scrub-decoder-regression.txt")
    }

    @MainActor
    @Test func playDuringLeftOverscrollPresentsTheExactFirstFrameUntilThePlayerStarts() async throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let player = ControlledSeekPlayer()
        model.player = player
        model.preparePlaybackAudio = {}
        model.beginScrub()
        var frame: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 96, 96, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &frame) == kCVReturnSuccess)
        let buffer = try #require(frame)
        model.renderService.livePreviewState.cacheFrame(buffer, at: model.livePreviewPresentationTime(0),
            sessionID: model.previewRenderSessionID,
            revision: model.renderService.livePreviewState.snapshot().revision)
        let observation = model.playbackState.$playbackStartRequestRevision.dropFirst().sink { _ in
            // Match TimelineScrollContainer.interruptScrubForPlayback's
            // synchronous flush while the left bounce is still outside zero.
            model.updateCurrentTime(model.clampedTimelineTime(-0.2))
        }
        model.togglePlayback()
        #expect(model.livePreviewPresentation.frame === buffer)
        #expect(model.playbackState.isStartingPlayback)
        #expect(!model.isScrubbing)
        for _ in 0..<100 where player.playCalls == 0 { await Task.yield() }
        #expect(player.playCalls == 1)
        #expect(player.seekRequests.isEmpty)
        #expect(model.livePreviewPresentation.frame == nil)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    @Test func playbackRequestBeforePlayerInstallationCanBeQueuedAndCancelled() {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        model.rebuildTask = Task { try? await Task.sleep(for: .seconds(10)) }
        #expect(model.player == nil)

        model.togglePlayback()
        #expect(model.pendingPlaybackResumeAfterPreviewRebuild)
        #expect(model.playbackState.isStartingPlayback)
        model.togglePlayback()
        #expect(!model.pendingPlaybackResumeAfterPreviewRebuild)
        #expect(!model.playbackState.isStartingPlayback)
    }

    @MainActor
    @Test func playTakesOverAnActiveScrubWithoutARebuildOrLatePositionJump() async {
        let viewModel = makeGeneratedLayerViewModel()
        viewModel.preparePlaybackAudio = {}
        defer { viewModel.stop() }
        let player = ControlledSeekPlayer()
        viewModel.player = player
        viewModel.beginScrub()
        viewModel.updateScrub(to: 0.2)
        for _ in 0..<100 where player.pendingSeekCount < 1 { await Task.yield() }
        guard player.pendingSeekCount == 1 else { Issue.record("Scrub seek missing"); return }
        viewModel.updateScrub(to: 0.7)
        viewModel.togglePlayback()
        #expect(!viewModel.isScrubbing)
        #expect(viewModel.playbackState.isStartingPlayback)
        #expect(viewModel.rebuildTask == nil)
        viewModel.updateScrub(to: 0.1)
        viewModel.endScrub(at: 0.2)
        #expect(viewModel.currentTime == 0.7)
        for _ in 0..<100 where player.pendingSeekCount < 2 { await Task.yield() }
        guard player.pendingSeekCount == 2 else { Issue.record("Play handoff seek missing"); return }
        #expect(player.seekRequests[1].time == 0.7)
        player.completeSeek(at: 0, finished: true)
        for _ in 0..<5 { await Task.yield() }
        #expect(viewModel.currentTime == 0.7)
        #expect(!viewModel.isPlaying)
        player.completeSeek(at: 1, finished: true)
        for _ in 0..<100 where !viewModel.isPlaying { await Task.yield() }
        #expect(viewModel.isPlaying)
        #expect(!viewModel.playbackState.isStartingPlayback)
        viewModel.updateScrub(to: 0.1)
        #expect(viewModel.currentTime == 0.7)
    }

    @MainActor
    @Test func secondPlayPressCancelsPendingScrubHandoff() async {
        let viewModel = makeGeneratedLayerViewModel()
        defer { viewModel.stop() }
        let player = ControlledSeekPlayer()
        viewModel.player = player
        viewModel.beginScrub()
        viewModel.updateScrub(to: 0.5)
        viewModel.togglePlayback()
        for _ in 0..<100 where player.pendingSeekCount < 1 { await Task.yield() }
        guard player.pendingSeekCount == 1 else { Issue.record("Handoff seek missing"); return }
        viewModel.togglePlayback()
        #expect(!viewModel.playbackState.isStartingPlayback)
        player.completeSeek(at: 0, finished: true)
        for _ in 0..<10 { await Task.yield() }
        #expect(!viewModel.isPlaying)
    }

    @MainActor
    @Test func cancelledSeekIsSupersededWithoutTriggeringRecovery() async {
        let viewModel = makeGeneratedLayerViewModel()
        defer { viewModel.stop() }
        let player = ControlledSeekPlayer()
        viewModel.player = player
        let oldSeek = Task { await viewModel.boundedSeek(
            player: player, to: 0.1, toleranceBefore: .zero, toleranceAfter: .zero,
            timeoutNanoseconds: 1_000_000_000
        ) }
        for _ in 0..<100 where player.pendingSeekCount < 1 { await Task.yield() }
        #expect(player.pendingSeekCount == 1)
        let latestSeek = Task { await viewModel.boundedSeek(
            player: player, to: 0.5, toleranceBefore: .zero, toleranceAfter: .zero,
            timeoutNanoseconds: 1_000_000_000
        ) }
        for _ in 0..<100 where player.pendingSeekCount < 2 { await Task.yield() }
        guard player.pendingSeekCount == 2 else {
            Issue.record("Expected both seek requests to reach AVPlayer")
            return
        }
        player.completeSeek(at: 0, finished: false)
        #expect(await oldSeek.value == .superseded)
        #expect(viewModel.isPreviewSeekInFlight)
        player.completeSeek(at: 1, finished: true)
        #expect(await latestSeek.value == .completed)
        #expect(!viewModel.isPreviewSeekInFlight)
        #expect(viewModel.previewRecoveryAttemptCount == 0)
    }

    @MainActor
    @Test func cancellingSeekTaskDoesNotWaitForFiveSecondDecoderTimeout() async {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let player = ControlledSeekPlayer()
        model.player = player
        let seek = Task { await model.boundedSeek(
            player: player, to: 0.3, toleranceBefore: .zero, toleranceAfter: .zero,
            timeoutNanoseconds: 5_000_000_000
        ) }
        for _ in 0..<100 where player.pendingSeekCount < 1 { await Task.yield() }
        #expect(player.pendingSeekCount == 1)
        let started = ContinuousClock.now
        seek.cancel()
        #expect(await seek.value == .superseded)
        #expect(started.duration(to: .now) < .milliseconds(100))
        #expect(!model.isPreviewSeekInFlight)
        #expect(model.previewRecoveryAttemptCount == 0)
        // The decoder can still deliver a late callback; it cannot resume twice.
        player.completeSeek(at: 0, finished: true)
    }

    @MainActor
    @Test func workspaceScrollDefersCommitWorkAndResumesItOnceAfterDeceleration() {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let owner = UUID()
        let secondOwner = UUID()
        model.setWorkspaceScrolling(true, owner: owner)
        model.setWorkspaceScrolling(true, owner: secondOwner)
        model.schedulePreviewRebuild(invalidation: [.previewFrame])
        model.schedulePreviewRebuild(invalidation: [.audioMix, .compositionTopology])
        model.persist()
        model.scheduleLivePreviewFrameRefresh()
        #expect(model.rebuildTask == nil)
        #expect(model.autosaveTask == nil)
        #expect(!model.livePreviewFrameRefreshInFlight)
        #expect(model.workspacePersistencePending)
        #expect(model.pendingPreviewInvalidation == [.previewFrame, .audioMix, .compositionTopology])
        model.setWorkspaceScrolling(false, owner: owner)
        #expect(model.rebuildTask == nil)
        model.setWorkspaceScrolling(false, owner: secondOwner)
        #expect(model.rebuildTask != nil)
        #expect(model.autosaveTask != nil)
        let generation = model.previewGeneration
        model.setWorkspaceScrolling(false, owner: secondOwner)
        #expect(model.previewGeneration == generation)
    }

    @MainActor
    @Test func seekInterruptionIsDistinctFromTimeoutAndLateCompletionIsIgnored() async {
        let viewModel = makeGeneratedLayerViewModel()
        defer { viewModel.stop() }
        let player = ControlledSeekPlayer()
        viewModel.player = player
        let interrupted = Task { await viewModel.boundedSeek(
            player: player, to: 0, toleranceBefore: .zero, toleranceAfter: .zero,
            timeoutNanoseconds: 1_000_000_000
        ) }
        for _ in 0..<100 where player.pendingSeekCount < 1 { await Task.yield() }
        guard player.pendingSeekCount == 1 else {
            Issue.record("Expected seek request")
            return
        }
        player.completeSeek(at: 0, finished: false)
        #expect(await interrupted.value == .interrupted)
        let timedOut = await viewModel.boundedSeek(
            player: player, to: 0.2, toleranceBefore: .zero, toleranceAfter: .zero,
            timeoutNanoseconds: 1_000_000
        )
        #expect(timedOut == .timedOut)
        player.completeSeek(at: 1, finished: true)
        #expect(!viewModel.isPreviewSeekInFlight)
    }

    @MainActor
    @Test func playbackRetriesPreviewAfterRecoveryCircuitOpened() {
        let viewModel = makeGeneratedLayerViewModel()
        defer { viewModel.stop() }
        viewModel.previewRecoveryCircuitIsOpen = true
        viewModel.togglePlayback()
        #expect(!viewModel.previewRecoveryCircuitIsOpen)
        #expect(viewModel.pendingPlaybackResumeAfterPreviewRebuild)
        #expect(viewModel.rebuildTask != nil)
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
    @Test func playbackStartFlushesPendingEditBeforeResuming() async throws {
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
        let flushedRebuild = try #require(viewModel.rebuildTask)
        #expect(viewModel.previewGeneration == previewGeneration + 2)
        #expect(viewModel.pendingPlaybackResumeAfterPreviewRebuild)
        #expect(!viewModel.isPlaying)
        await flushedRebuild.value
        #expect(viewModel.isPlaying)
        #expect(viewModel.pendingPreviewInvalidation.isEmpty)
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
        viewModel.isPlaying = true

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
    @Test func replacingPreviewPlayerKeepsTheVisibleLayerConnected() async throws {
        let viewModel = makeGeneratedLayerViewModel()
        defer { viewModel.stop() }
        let layer = viewModel.livePreviewPresentation.playerLayer
        let firstItem = AVPlayerItem(asset: AVMutableComposition())
        viewModel.replacePreviewPlayer(with: firstItem)
        let firstPlayer = try #require(viewModel.player)
        #expect(layer.player === firstPlayer)

        let secondItem = AVPlayerItem(asset: AVMutableComposition())
        viewModel.replacePreviewPlayer(with: secondItem)

        #expect(viewModel.player !== firstPlayer)
        #expect(viewModel.player?.currentItem === secondItem)
        #expect(layer.player === viewModel.player)
        viewModel.replacePreviewPlayer(with: nil)
        #expect(layer.player == nil)
    }

    @MainActor
    @Test func backgroundPreviewIgnoresStaleFailuresAndRebuildsAtTheSamePlayhead() async throws {
        let model = makeGeneratedLayerViewModel(duration: 120.01)
        defer { model.stop() }
        let time = 119.5
        let invalidation: EditorInvalidation = [.previewFrame, .compositionTopology, .audioMix]
        model.schedulePreviewRebuild(seekTo: time, delay: false, invalidation: invalidation)
        await model.rebuildTask?.value
        let original = try #require(model.player)
        let originalSession = model.previewRenderSessionID
        model.schedulePreviewRecovery(reason: .compositorFailure, resumePlayback: false)

        model.suspendPreview()
        #expect(model.player == nil)
        #expect(model.rebuildTask == nil)
        for _ in 0..<6 { model.schedulePreviewRecovery(reason: .seekTimeout, resumePlayback: false) }
        NotificationCenter.default.post(name: .motionaryVideoCompositorPersistentFailure, object: nil,
            userInfo: ["renderSessionID": originalSession])
        try await Task.sleep(for: .milliseconds(450))
        #expect(!model.previewRecoveryCircuitIsOpen)
        #expect(model.currentTime == time)

        model.resumePreview()
        await model.rebuildTask?.value
        let restored = try #require(model.player)
        #expect(restored !== original)
        #expect(model.previewRenderSessionID != originalSession)
        #expect(abs(restored.currentTime().seconds - time) < 1 / 30)
        #expect(model.currentTime == time)
        #expect(model.previewRecoveryAttemptCount == 0)
        #expect(!model.isPlaying)
    }

    @MainActor
    @Test func duplicateRecoverySignalsShareOneAttempt() {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        for _ in 0..<6 {
            model.schedulePreviewRecovery(reason: .compositorFailure, resumePlayback: false)
        }
        #expect(model.previewRecoveryAttemptCount == 1)
        #expect(!model.previewRecoveryCircuitIsOpen)
    }

    @MainActor
    @Test func repeatedPreviewRecoveryOpensCircuitInsteadOfLoopingForever() async throws {
        let viewModel = makeGeneratedLayerViewModel()
        defer { viewModel.stop() }
        viewModel.player = AVPlayer()
        viewModel.isPlaying = true

        await exhaustPreviewRecovery(for: viewModel)

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

        await exhaustPreviewRecovery(for: viewModel)
        #expect(viewModel.previewRecoveryCircuitIsOpen)

        viewModel.schedulePreviewRebuild(seekTo: 0.2, delay: false, invalidation: [.previewFrame])

        #expect(!viewModel.previewRecoveryCircuitIsOpen)
        #expect(viewModel.rebuildTask != nil)
    }

    @MainActor
    private func exhaustPreviewRecovery(for model: EditorViewModel) async {
        for _ in 0..<4 {
            model.schedulePreviewRecovery(reason: .playerItemFailed, resumePlayback: false)
            await model.previewRecoveryTask?.value
            model.rebuildTask?.cancel()
        }
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
        #expect(viewModel.pendingPreviewInvalidation.contains(.previewFrame))
        #expect(viewModel.pendingPreviewInvalidation.contains(.compositionTopology))
        #expect(viewModel.pendingPreviewInvalidation.contains(.audioMix))
        #expect(viewModel.rebuildTask != nil)
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
    @Test func playbackRetriesAnInterruptedSeekAfterAnEdit() async throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let player = ControlledSeekPlayer()
        player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
        model.player = player
        model.preparePlaybackAudio = {}
        let start = model.startPreparedPlayback(player, seekTo: 0.2)
        defer { start.cancel() }
        for _ in 0..<200 where player.pendingSeekCount < 1 { try await Task.sleep(for: .milliseconds(2)) }
        try #require(player.pendingSeekCount == 1)
        player.completeSeek(at: 0, finished: false)
        for _ in 0..<200 where player.pendingSeekCount < 2 { try await Task.sleep(for: .milliseconds(2)) }
        try #require(player.pendingSeekCount == 2)
        #expect(player.playCalls == 0)
        player.completeSeek(at: 1, finished: true)
        await start.value
        #expect(player.playCalls == 1)
    }

    @MainActor
    @Test func pausedPreviewRetriesAnAcknowledgedSeekThatProducedNoFrame() async throws {
        let model = makeGeneratedLayerViewModel()
        defer { model.stop() }
        let session = model.previewRenderSessionID
        let preview = try #require(try await model.renderService.preparePreview(
            for: model.project, quality: .balanced, invalidation: [.compositionTopology],
            renderSessionID: session))
        let item = AVPlayerItem(asset: preview.composition)
        item.videoComposition = try #require(preview.videoComposition)
        let player = ControlledSeekPlayer()
        player.replaceCurrentItem(with: item)
        model.player = player
        model.updateCurrentTime(0.2)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let held = try #require(buffer)
        model.livePreviewPresentation.setFrame(held, at: 0)

        model.scheduleLivePreviewFrameRefresh()
        for _ in 0..<200 where player.pendingSeekCount < 1 { try await Task.sleep(for: .milliseconds(2)) }
        try #require(player.pendingSeekCount == 1)
        player.completeSeek(at: 0, finished: true)
        for _ in 0..<200 where player.pendingSeekCount < 2 { try await Task.sleep(for: .milliseconds(2)) }
        try #require(player.pendingSeekCount == 2)
        #expect(model.livePreviewPresentation.frame === held)

        var result: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &result) == kCVReturnSuccess)
        let fresh = try #require(result)
        let state = model.renderService.livePreviewState
        let target = model.canonicalPreviewFrameTime(model.currentTime)
        state.cacheFrame(fresh, at: target, sessionID: session, revision: state.snapshot().revision)
        player.completeSeek(at: 1, finished: true)
        await model.livePreviewSeekTask?.value
        #expect(model.livePreviewPresentation.frame === fresh)
        #expect(!model.livePreviewFrameRefreshInFlight)
        #expect(model.previewRecoveryAttemptCount == 0)
    }

    @MainActor
    @Test func committingConstantSpeedIssuesOneRebuildAtTheAnchoredPlayhead() {
        let clip = TimelineClip(name: "Speed", source: ClipSource(
            url: URL(fileURLWithPath: "/tmp/constant-speed.mov"), mediaType: .video, originalDuration: 4),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 4))
        let model = makeViewModel(clip: clip)
        defer { model.stop() }
        model.selectTimelineItem(clip.id, trackID: model.project.tracks[0].id)
        model.updateCurrentTime(1.5)
        let generation = model.previewGeneration

        #expect(model.setSelectedConstantSpeed(0.5))
        #expect(model.previewGeneration == generation + 1)
        #expect(model.currentTime == 3)
        #expect(model.undoStack.count == 1)
    }

    @MainActor
    @Test func movingTimeRemapKeyframeUsesLiveMappingUntilCommit() throws {
        let clip = TimelineClip(name: "Remap", source: ClipSource(
            url: URL(fileURLWithPath: "/tmp/time-remapping.mov"), mediaType: .video, originalDuration: 4),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 4))
        let model = makeViewModel(clip: clip)
        defer { model.stop() }
        var speedMap = SpeedMap.constant
        var remap = try #require(TimeRemap(sourceDuration: 4, timelineDuration: 4))
        remap.setSourceTime(2.5, at: 1, tolerance: 0.001)
        speedMap.timeRemap = remap
        model.project.setSpeedMap(for: clip.id, speedMap: speedMap)
        model.selectTimelineItem(clip.id, trackID: model.project.tracks[0].id)
        let generation = model.previewGeneration

        #expect(model.moveTimelineKeyframes(itemID: clip.id, section: .speed, effectID: nil,
            from: 1, to: 1.5, interactive: true))
        let live = model.renderService.livePreviewState.snapshot().override(for: clip.id)?.speedMap
        #expect(live?.sourceTime(at: 1.5, sourceDuration: 4) == 2.5)
        #expect(model.previewGeneration == generation)
        #expect(model.rebuildTask == nil)

        model.finishInteractiveEdit()
        #expect(model.previewGeneration == generation + 1)
        #expect(model.undoStack.count == 1)
    }

    @MainActor
    @Test func directLiveFramesCoalesceWithoutSeeksAndCannotCoverScrubbing() async throws {
        let viewModel = makeViewModel()
        defer { viewModel.stop() }
        let player = ControlledSeekPlayer()
        player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
        viewModel.player = player
        var callbacks: [(CVPixelBuffer?) -> Void] = []
        viewModel.renderService.livePreviewState.installPausedFrameRenderer { _, _, _, completion in
            callbacks.append(completion)
            return true
        }
        let itemID = UUID()
        viewModel.updateLivePreviewTransform(ClipTransform(), for: itemID, immediate: false)
        #expect(callbacks.count == 1)
        #expect(viewModel.livePreviewFrameRefreshTask == nil)
        var latest = ClipTransform()
        latest.positionX.baseValue = 20
        viewModel.updateLivePreviewTransform(latest, for: itemID, immediate: false)
        #expect(callbacks.count == 1)
        #expect(player.pendingSeekCount == 0)
        #expect(viewModel.pendingLivePreviewFrameRefresh)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                                   kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        callbacks[0](frame)
        for _ in 0..<100 {
            if callbacks.count == 2 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(callbacks.count == 2)
        #expect(viewModel.livePreviewFrameRefreshTask == nil)
        #expect(viewModel.livePreviewPresentation.frame === frame)
        #expect(player.pendingSeekCount == 0)
        #expect(viewModel.renderService.livePreviewState.transform(for: itemID) == latest)

        viewModel.beginScrub()
        #expect(viewModel.livePreviewPresentation.frame == nil)
        // Even if the user has already finished scrubbing before GPU work
        // completes, its older generation must never reappear over the player.
        viewModel.isScrubbing = false
        callbacks[1](frame)
        await Task.yield()
        #expect(viewModel.livePreviewPresentation.frame == nil)
        #expect(!viewModel.livePreviewFrameRefreshInFlight)
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

        #expect(instruction.renderSize == CGSize(width: 540, height: 960))
        #expect(abs(instruction.renderScale - 540.0 / 1080.0) < 0.000_001)
        #expect(instruction.vectorRenderScale == 0.75)
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

        #expect(instruction.renderSize == CGSize(width: 540, height: 960))
        #expect(abs(instruction.renderScale - 540.0 / 1080.0) < 0.000_001)
        #expect(instruction.vectorRenderScale == 0.75)
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
    private func makeGeneratedLayerViewModel(duration: Double = 1) -> EditorViewModel {
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
            sourceRange: TimeRangeValue(start: 0, duration: duration)
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
