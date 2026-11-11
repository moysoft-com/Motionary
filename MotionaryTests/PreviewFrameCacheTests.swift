import CoreVideo
import Foundation
import Testing
@testable import Motionary

struct PreviewFrameCacheTests {
    private func buffer() throws -> CVPixelBuffer {
        var frame: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &frame) == kCVReturnSuccess)
        return try #require(frame)
    }

    @Test func completedFramesKeepTheirIdentityAndRespectLRUEviction() throws {
        let first = try buffer(), second = try buffer(), third = try buffer()
        let cost = CVPixelBufferGetBytesPerRow(first) * CVPixelBufferGetHeight(first)
        let cache = PreviewFrameCache(byteLimit: cost * 2)
        let session = UUID()
        cache.store(first, at: 0.1, sessionID: session, revision: 1)
        cache.store(second, at: 0.2, sessionID: session, revision: 1)
        #expect(cache.frame(at: 0.1, sessionID: session, revision: 1) === first)
        cache.store(third, at: 0.3, sessionID: session, revision: 1)
        #expect(cache.frame(at: 0.2, sessionID: session, revision: 1) == nil)
        #expect(cache.frame(at: 0.1, sessionID: session, revision: 1) === first)
        #expect(cache.frame(at: 0.3, sessionID: session, revision: 1) === third)
        #expect(cache.frame(at: 0.1, sessionID: UUID(), revision: 1) == nil)
        #expect(cache.frame(at: 0.1, sessionID: session, revision: 2) == nil)
        cache.removeAll()
        #expect(cache.frame(at: 0.1, sessionID: session, revision: 1) == nil)
    }

    @Test func oversizedAndInvalidFramesDoNotDisplaceUsefulEntries() throws {
        let frame = try buffer()
        let cache = PreviewFrameCache(byteLimit: 1)
        let session = UUID()
        cache.store(frame, at: 0, sessionID: session, revision: 0)
        cache.store(frame, at: .nan, sessionID: session, revision: 0)
        #expect(cache.frame(at: 0, sessionID: session, revision: 0) == nil)
        #expect(cache.frame(at: .infinity, sessionID: session, revision: 0) == nil)
    }

    @Test func tinyCanvasEntriesAlsoHaveABoundedCount() throws {
        let frame = try buffer()
        let cache = PreviewFrameCache(byteLimit: 1_024 * 1_024, countLimit: 2)
        let session = UUID()
        for time in [0.1, 0.2, 0.3] { cache.store(frame, at: time, sessionID: session, revision: 0) }
        #expect(cache.frame(at: 0.1, sessionID: session, revision: 0) == nil)
        #expect(cache.frame(at: 0.2, sessionID: session, revision: 0) === frame)
        #expect(cache.frame(at: 0.3, sessionID: session, revision: 0) === frame)
    }

    @Test func nearbyFramesServeScrubFallbacksButNeverExactRequests() throws {
        let frame = try buffer()
        let cache = PreviewFrameCache(byteLimit: 1_024 * 1_024, countLimit: 8)
        let session = UUID()
        cache.store(frame, at: 0.5, sessionID: session, revision: 1)
        let window = 1 / 30.0
        let near = cache.frameNear(at: 0.5 + window, sessionID: session, window: window, revision: 1)
        #expect(near?.frame === frame)
        #expect(abs((near?.time ?? -1) - 0.5) < 0.0001)
        #expect(cache.frameNear(at: 0.5 + 3 * window, sessionID: session, window: window, revision: 1) == nil)
        #expect(cache.frameNear(at: 0.5, sessionID: UUID(), window: window, revision: 1) == nil)
        #expect(cache.frame(at: 0.5 + window, sessionID: session, revision: 1) == nil)
        // Editing can remap source content at this time; never resurrect it.
        let nearOldRevision = cache.frameNear(at: 0.5 + window, sessionID: session, window: window, revision: 2)
        #expect(nearOldRevision == nil)
        cache.store(try buffer(), at: 0.5 + 2 * window, sessionID: session, revision: 1)
        let tied = cache.frameNear(at: 0.5 + window, sessionID: session, window: window, revision: 1)
        #expect(tied?.frame === frame)
    }

    @Test func visualEditsAndGraphRebuildsRejectStaleGPUCompletions() throws {
        let state = LivePreviewRenderState()
        let session = UUID(), clip = UUID()
        let frame = try buffer()
        let original = state.snapshot().revision
        state.cacheFrame(frame, at: 0.5, sessionID: session, revision: original)
        state.setInteractiveQualityOverride(true)
        #expect(state.cachedFrame(at: 0.5, sessionID: session) === frame)
        state.setTransform(ClipTransform(), for: clip)
        #expect(state.cachedFrame(at: 0.5, sessionID: session) == nil)
        state.cacheFrame(frame, at: 0.5, sessionID: session, revision: original)
        #expect(state.cachedFrame(at: 0.5, sessionID: session) == nil)
        let edited = state.snapshot().revision
        state.cacheFrame(frame, at: 0.5, sessionID: session, revision: edited)
        #expect(state.cachedFrame(at: 0.5, sessionID: session) === frame)
        state.invalidateComposedFrames()
        state.cacheFrame(frame, at: 0.5, sessionID: session, revision: edited)
        #expect(state.cachedFrame(at: 0.5, sessionID: session) == nil)
    }
}
