import CoreGraphics
import Foundation
import Testing

@testable import Motionary

@Suite("Render-context cache retention")
struct RenderContextCachePolicyTests {
    @Test("Initial and equivalent render contexts retain renderer resources")
    func equivalentContextsRetainResources() {
        var policy = RenderContextCachePolicy()

        let initialRegistrationPurges = policy.register(
            renderSize: CGSize(width: 1_080, height: 1_920)
        )
        let identicalRegistrationPurges = policy.register(
            renderSize: CGSize(width: 1_080, height: 1_920)
        )
        let subpixelRegistrationPurges = policy.register(
            renderSize: CGSize(width: 1_080.4, height: 1_919.7)
        )

        #expect(!initialRegistrationPurges)
        #expect(!identicalRegistrationPurges)
        #expect(!subpixelRegistrationPurges)
    }

    @Test("A material render-size transition purges size-dependent resources once")
    func sizeTransitionPurgesResourcesOnce() {
        var policy = RenderContextCachePolicy()
        _ = policy.register(renderSize: CGSize(width: 960, height: 540))

        let materialTransitionPurges = policy.register(
            renderSize: CGSize(width: 1_280, height: 720)
        )
        let repeatedRegistrationPurges = policy.register(
            renderSize: CGSize(width: 1_280, height: 720)
        )

        #expect(materialTransitionPurges)
        #expect(!repeatedRegistrationPurges)
    }

    @Test("Responsive frame acquire exits instead of blocking cancelled playback")
    func responsiveFrameAcquireHonorsCancellation() throws {
        let resources = try MetalRenderResources()
        var frames: [MetalFrameResources] = []
        defer {
            frames.forEach { $0.abandon() }
        }
        for _ in 0..<MetalRenderResources.maximumInFlightFrames {
            frames.append(try resources.beginFrame())
        }

        let startedAt = Date()
        do {
            _ = try resources.beginFrame(isCancelled: { true })
            Issue.record("Cancelled responsive frame acquire unexpectedly succeeded.")
        } catch MetalRenderingError.cancelled {
            #expect(Date().timeIntervalSince(startedAt) < 0.05)
        }
    }
}
