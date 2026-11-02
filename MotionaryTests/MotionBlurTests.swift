import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import Motionary

struct MotionBlurTests {
    private let bounds = CGRect(x: 0, y: 0, width: 128, height: 64)

    private func pixels(_ image: CIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 128 * 64 * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: 128 * 4, bounds: bounds,
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return bytes
    }

    @Test(arguments: ["Position", "Rotation", "Scale"])
    func shutterIntegratesOnlySelectedObjectMotion(component: String) throws {
        let renderer = try MetalFrameRenderer()
        let input = CIImage(color: .white).cropped(to: CGRect(x: 84, y: 25, width: 8, height: 12))
            .composited(over: CIImage(color: .clear).cropped(to: bounds))
        var transform = ClipTransform()
        switch component {
        case "Position":
            transform.positionX = AnimatableProperty(baseValue: 0, keyframes: [
                Keyframe(time: 0, value: -1), Keyframe(time: 1, value: 1)
            ])
        case "Rotation":
            transform.rotationDegrees = AnimatableProperty(baseValue: 0, keyframes: [
                Keyframe(time: 0, value: -180), Keyframe(time: 1, value: 180)
            ])
        default:
            transform.scale = AnimatableScale(keyframes: [
                Keyframe(time: 0, value: ScaleValue(x: 0.2, y: 0.2)),
                Keyframe(time: 1, value: ScaleValue(x: 1.8, y: 1.8))
            ])
        }
        let motion = EffectLayerMotion(transform: transform, canvasSize: bounds.size, isGenerated: false)
        var blur = try #require(EffectRegistry.shared.makeEffect(moduleID: .motionBlur))
        blur.parameters["shutter"] = EffectParameterState(baseValue: .scalar(720))
        func render(_ selection: String, motion: EffectLayerMotion?) throws -> CIImage {
            blur.parameters["motion"] = EffectParameterState(baseValue: .option(selection))
            return try renderer.renderEffectsSynchronously(EffectStack(effects: [blur]),
                to: input, at: 0.5, renderScale: 1, quality: .export, temporalSource: EffectTemporalSource(
                    url: URL(fileURLWithPath: "/missing-video-must-never-be-decoded.mov"),
                    sourceStart: 0, sourceDuration: 1, speedMap: .constant(speed: 1)),
                layerMotion: motion)
        }
        let original = pixels(input)
        #expect(pixels(try render(component, motion: motion)) != original)
        #expect(pixels(try render("All", motion: motion)) != original)
        #expect(pixels(try render("None", motion: motion)) == original)
        let excluded = component == "Position" ? "Rotation + Scale" : component == "Rotation" ? "Position + Scale" : "Position + Rotation"
        #expect(pixels(try render(excluded, motion: motion)) == original)
        #expect(pixels(try render("All", motion: nil)) == original)
        blur.parameters["shutter"] = EffectParameterState(baseValue: .scalar(0))
        #expect(pixels(try render("All", motion: motion)) == original)
    }

    @Test func blurExpandsBoundsInsteadOfClippingObjectTrails() throws {
        let renderer = try MetalFrameRenderer()
        let input = CIImage(color: .white).cropped(to: bounds)
        let transform = ClipTransform(positionX: AnimatableProperty(baseValue: 0, keyframes: [
            Keyframe(time: 0, value: -1), Keyframe(time: 1, value: 1)
        ]))
        let blur = try #require(EffectRegistry.shared.makeEffect(moduleID: .motionBlur))
        let result = try renderer.renderEffectsSynchronously(EffectStack(effects: [blur]),
            to: input, at: 0.5, renderScale: 1, quality: .export,
            layerMotion: EffectLayerMotion(transform: transform, canvasSize: bounds.size, isGenerated: false))
        #expect(result.extent.minX < bounds.minX)
        #expect(result.extent.maxX >= bounds.maxX)
    }

    @MainActor @Test func adjustmentLayerBlursOnlyUnderlyingAnimatedObjects() async throws {
        var shape = ShapeTimelineItem(name: "Moving object", mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle, color: .white, width: 12, height: 12),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 1))
        shape.visuals.transform.positionX = AnimatableProperty(baseValue: 0, keyframes: [
            Keyframe(time: 0, value: -1), Keyframe(time: 1, value: 1)
        ])
        var adjustment = AdjustmentTimelineItem(timelineStart: 0.1, duration: 0.9)
        var blur = try #require(EffectRegistry.shared.makeEffect(moduleID: .motionBlur))
        blur.parameters["shutter"] = EffectParameterState(baseValue: .scalar(720))
        adjustment.visuals.effectStack = EffectStack(effects: [blur])
        let shapeTrack = TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])
        func frame(tracks: [TimelineTrack]) async throws -> [UInt8] {
            let project = EditorProject(title: "Motion blur", renderSettings:
                RenderSettings(width: 128, height: 64, frameRate: 30), tracks: tracks)
            let rendered = try await CompositionRenderService().makeComposition(for: project)
            let generator = AVAssetImageGenerator(asset: rendered.composition)
            generator.videoComposition = rendered.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return pixels(CIImage(cgImage: try await generator.image(
                at: CMTime(seconds: 0.5, preferredTimescale: 600)).image))
        }
        let sharp = try await frame(tracks: [shapeTrack])
        let adjustmentTrack = TimelineTrack(name: "Blur", kind: .visual, items: [.adjustment(adjustment)])
        let blurred = try await frame(tracks: [adjustmentTrack, shapeTrack])
        #expect(blurred != sharp)
        // The same adjustment below the object must leave it sharp.
        #expect(try await frame(tracks: [shapeTrack, adjustmentTrack]) == sharp)
        adjustment.visuals.transform.opacity.baseValue = 0
        #expect(try await frame(tracks: [TimelineTrack(name: "Hidden blur", kind: .visual,
            items: [.adjustment(adjustment)]), shapeTrack]) == sharp)
    }

    @Test func animatedLibraryFramesChangeAndUseStableSeeds() throws {
        for id: EffectModuleID in [.cameraWiggle, .zoom, .lightSweep, .motionBlur] {
            #expect(EffectRegistry.shared.descriptor(for: id)?.hasAnimatedPreview == true)
            let first = try #require(EffectThumbnailRenderer.preview(for: id, at: 0.2, animated: true)?.pngData())
            let next = try #require(EffectThumbnailRenderer.preview(for: id, at: 0.7, animated: true)?.pngData())
            let repeated = try #require(EffectThumbnailRenderer.preview(for: id, at: 0.2, animated: true)?.pngData())
            #expect(first != next)
            #expect(first == repeated, "\(id.rawValue) preview must keep its motion seed across frames")
        }
        #expect(EffectRegistry.shared.descriptor(for: .noir)?.hasAnimatedPreview == false)
    }
}
