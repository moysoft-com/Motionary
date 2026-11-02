import CoreImage
import Foundation
import Testing
@testable import Motionary

struct RemovedReverseTimeTests {
    @Test func reverseTimeIsUnavailableAndLegacyMarkersAreHarmless() throws {
        #expect(EffectRegistry.shared.makeEffect(moduleID: .reverseTime) == nil)
        #expect(EffectRegistry.shared.descriptor(for: .reverseTime) == nil)
        let legacy = EffectInstance(moduleID: .reverseTime)
        let stack = EffectStack(effects: [legacy])
        try EffectRenderRegistry.shared.validate(stack)
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let renderer = try MetalFrameRenderer()
        let result = try renderer.renderEffectsSynchronously(stack, to: image, at: 0.5,
            renderScale: 1, quality: .export)
        #expect(result.extent == image.extent)
    }
}
