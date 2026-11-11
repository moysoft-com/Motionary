import AVFoundation
import CoreVideo
import Foundation
import Testing

@testable import Motionary

/// Leaves seeks pending until the test delivers the AVFoundation callback.
private final class RefreshControlledSeekPlayer: AVPlayer, @unchecked Sendable {
    private let callbackLock = NSLock()
    private var callbacks: [(@Sendable (Bool) -> Void)] = []
    private var requests: [(time: Double, tolerance: Double)] = []

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

@Suite(.serialized)
struct PreviewRefreshTests {
    @MainActor
    @Test func completedBootstrapRevealsCanonicalPlayerFrameWithoutAnotherEdit() async throws {
        let (model, player) = makeModel()
        defer { model.stop() }
        model.livePreviewPresentation.frame = try makeFrame()
        model.scheduleLivePreviewFrameRefresh()
        try await waitUntil { player.pendingSeekCount == 1 }
        player.completeSeek(at: 0, finished: true)
        try await waitUntil { !model.livePreviewFrameRefreshInFlight }
        #expect(model.livePreviewPresentation.frame == nil)
        #expect(!model.pendingLivePreviewFrameRefresh)
        #expect(player.pendingSeekCount == 1)
        #expect(model.currentTime == 0.5)
        #expect(!model.isPlaying)
    }

    @MainActor
    @Test(arguments: [false, true], [false, true])
    func obsoleteRefreshCannotCoverNewGraphAndRetainsLatestRequest(cached: Bool, rotatesSession: Bool) async throws {
        let (model, player) = makeModel()
        defer { model.stop() }
        let previous = try makeFrame()
        let obsolete = try makeFrame()
        let latest = try makeFrame()
        model.livePreviewPresentation.frame = previous
        var oldCompletion: ((CVPixelBuffer?) -> Void)?
        if cached {
            model.renderService.livePreviewState.installPausedFrameRenderer { _, _, completion in
                oldCompletion = completion
                return true
            }
        }
        model.scheduleLivePreviewFrameRefresh()
        if !cached { try await waitUntil { player.pendingSeekCount == 1 } }
        if rotatesSession { model.previewRenderSessionID = UUID() }
        else { model.previewGeneration &+= 1 }
        var freshCompletion: ((CVPixelBuffer?) -> Void)?
        model.renderService.livePreviewState.installPausedFrameRenderer { _, _, completion in
            freshCompletion = completion
            return true
        }
        model.scheduleLivePreviewFrameRefresh()
        if cached {
            let complete = try #require(oldCompletion)
            complete(obsolete)
        } else {
            player.completeSeek(at: 0, finished: true)
        }
        try await waitUntil { freshCompletion != nil }
        #expect(model.livePreviewPresentation.frame === previous)
        let complete = try #require(freshCompletion)
        complete(latest)
        try await waitUntil { !model.livePreviewFrameRefreshInFlight }
        #expect(model.livePreviewPresentation.frame === latest)
        #expect(!model.pendingLivePreviewFrameRefresh)
        #expect(player.pendingSeekCount == (cached ? 0 : 1))
        #expect(model.currentTime == 0.5)
    }

    @MainActor
    @Test func interruptedBootstrapStillDeliversTheRequestedEdit() async throws {
        let (model, player) = makeModel()
        defer { model.stop() }
        model.livePreviewPresentation.frame = try makeFrame()
        model.scheduleLivePreviewFrameRefresh()
        try await waitUntil { player.pendingSeekCount == 1 }
        let latest = try makeFrame()
        model.renderService.livePreviewState.installPausedFrameRenderer { _, _, completion in
            completion(latest)
            return true
        }
        player.completeSeek(at: 0, finished: false)
        try await waitUntil { model.livePreviewPresentation.frame === latest }
        #expect(!model.livePreviewFrameRefreshInFlight)
        #expect(!model.pendingLivePreviewFrameRefresh)
        #expect(player.pendingSeekCount == 1)
    }

    @MainActor
    @Test func boundaryGestureKeepsLiveFrameUntilCanonicalPreviewIsRebuilt() throws {
        let (model, _) = makeModel()
        defer { model.stop() }
        let item = try #require(model.project.tracks.first?.items.first)
        let visuals = try #require(item.editableVisuals)
        let frame = try makeFrame()
        model.livePreviewPresentation.frame = frame
        model.beginInteractiveEdit()
        model.renderService.livePreviewState.setVisuals(visuals, for: item.id)
        model.pendingLiveVisualOverrideItemIDs.insert(item.id)
        model.pendingPreviewInvalidation.insert(.previewFrame)

        // A second drag at an endpoint does not change the project, but it
        // can interrupt the preceding edit's still-pending preview rebuild.
        model.finishInteractiveEdit(rebuild: true, delayRebuild: false)

        #expect(model.livePreviewPresentation.frame === frame)
        #expect(model.renderService.livePreviewState.override(for: item.id)?.visuals != nil)
        #expect(model.pendingLiveVisualOverrideItemIDs.contains(item.id))
        #expect(model.rebuildTask != nil)
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate(), "The paused preview did not deliver its refresh")
    }

    @MainActor
    private func makeModel() -> (EditorViewModel, RefreshControlledSeekPlayer) {
        let shape = ShapeTimelineItem(
            name: "Paused edits", mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle, color: .white, width: 64, height: 64),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        let model = EditorViewModel(
            projectID: UUID(), projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: EditorProject(
                title: "Paused refresh", renderSettings: RenderSettings(width: 96, height: 96, frameRate: 30),
                tracks: [TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])]
            ))
        )
        let player = RefreshControlledSeekPlayer()
        player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
        model.player = player
        model.currentTime = 0.5
        return (model, player)
    }

    private func makeFrame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
            kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        return try #require(buffer)
    }
}

