import CoreImage
import Foundation
import Testing
@testable import Motionary

@Suite(.serialized)
struct InteractiveEffectTests {
    @Test func interactionUsesTheSamePreviewResolutionAsPlayback() {
        #expect(PreviewQuality.interactive.maximumDimension == PreviewQuality.balanced.maximumDimension)
    }

    @Test func everyEffectKeepsItsAppearanceBetweenInteractionAndExport() throws {
        let renderer = try MetalFrameRenderer()
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 810)
        let input = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 1440, y: 810),
            "inputColor0": CIColor(red: 0.1, green: 0.25, blue: 0.7),
            "inputColor1": CIColor(red: 0.9, green: 0.65, blue: 0.15)
        ])!.outputImage!.cropped(to: bounds)
        let context = CIContext()
        func pixels(_ image: CIImage) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: 144 * 81 * 4)
            context.render(image.transformed(by: CGAffineTransform(scaleX: 0.1, y: 0.1)),
                toBitmap: &result, rowBytes: 144 * 4, bounds: CGRect(x: 0, y: 0, width: 144, height: 81),
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return result
        }
        for descriptor in EffectRegistry.shared.modules {
            let effect = try #require(EffectRegistry.shared.makeEffect(moduleID: descriptor.id))
            let stack = EffectStack(effects: [effect])
            let interactive = try renderer.renderEffectsSynchronously(stack, to: input,
                at: 0.7, renderScale: 1, quality: .interactive)
            let exported = try renderer.renderEffectsSynchronously(stack, to: input,
                at: 0.7, renderScale: 1, quality: .export)
            #expect(interactive.extent == exported.extent, "\(descriptor.name) bounds")
            let a = pixels(interactive), b = pixels(exported)
            let error = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count) / 255
            #expect(error < 0.00001, "\(descriptor.name) interaction/export image error: \(error)")
        }
    }

    @Test func proxyAndOriginalUseTheSameAuthoredEffectGrid() {
        let canvas = CGSize(width: 1920, height: 1080)
        for source in [CGSize(width: 720, height: 405), CGSize(width: 3840, height: 2160)] {
            for outputScale: CGFloat in [0.5, 1, 2] {
                let coordinates = LayerEffectCoordinates(isGeneratedLayer: false,
                    outputScale: outputScale, rasterScaleCorrection: CGSize(width: 1, height: 1),
                    mediaSize: source, canvasSize: canvas)
                let authored = CGRect(origin: .zero, size: source).applying(coordinates.inputTransform)
                #expect(authored.size == canvas)
                #expect(coordinates.renderScale == 1)
            }
        }
    }

    @Test func interactiveEchoRequiresItsHistoricalSamples() throws {
        let renderer = try MetalFrameRenderer()
        let input = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .echoTrails))
        #expect(throws: (any Error).self) {
            _ = try renderer.renderEffectsSynchronously(EffectStack(effects: [effect]),
                to: input, at: 0.8, renderScale: 1, quality: .interactive,
                temporalSource: EffectTemporalSource(url: URL(fileURLWithPath: "/missing-history.mov"),
                    sourceStart: 0, sourceDuration: 1, speedMap: .constant(speed: 1)))
        }
    }

    @Test func interactiveStackPreservesCanvasAndMeasuresGPUCost() throws {
        let renderer = try MetalFrameRenderer()
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let input = CIImage(color: .white).cropped(to: bounds.insetBy(dx: 240, dy: 180))
            .composited(over: CIImage(color: .black).cropped(to: bounds))
        let effects = try [EffectModuleID.waveWarp, .blur, .softGlow].map {
            try #require(EffectRegistry.shared.makeEffect(moduleID: $0))
        }
        let stack = EffectStack(effects: effects)
        var times: [RenderQualityProfile: [Double]] = [:]
        for index in 0..<5 {
            for quality in [RenderQualityProfile.balanced, .interactive] {
                let start = CFAbsoluteTimeGetCurrent()
                let image = try renderer.renderEffectsSynchronously(stack, to: input,
                    at: Double(index) / 30, renderScale: 1, quality: quality)
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                #expect(image.extent == bounds)
                if index > 0 { times[quality, default: []].append(elapsed) }
                var pixel = [UInt8](repeating: 0, count: 4)
                CIContext().render(image, toBitmap: &pixel, rowBytes: 4,
                    bounds: CGRect(x: 960, y: 540, width: 1, height: 1), format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                #expect(pixel[3] == 255)
                #expect(pixel[0] > 200)
            }
        }
        let report = times.map { quality, values in
            "\(quality.rawValue): \(values.reduce(0, +) / Double(values.count)) ms per frame"
        }.sorted().joined(separator: "\n")
        Attachment.record(report, named: "1080p-effect-stack-gpu-cost.txt")
    }
}
