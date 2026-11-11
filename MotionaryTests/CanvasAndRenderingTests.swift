// Canvas sizing and empty-composition rendering tests.

import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import Motionary

private final class DiagnosticsTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value += interval
        lock.unlock()
    }
}

private final class DiagnosticsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EffectRenderDiagnostic] = []

    func append(_ diagnostic: EffectRenderDiagnostic) {
        lock.lock()
        storage.append(diagnostic)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}

private final class AdjustmentExtentRecorder: EffectRenderModule, @unchecked Sendable {
    let moduleID: EffectModuleID = .sepia
    private(set) var extents: [CGRect] = []

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext,
                resources: MetalFrameResources) throws -> EffectRenderResult {
        extents.append(image.extent)
        return EffectRenderResult(image: image)
    }
}

private struct DistortionTextureBarrier: EffectRenderModule {
    let moduleID: EffectModuleID = .sepia

    func render(
        _ image: CIImage,
        effect: EffectInstance,
        context: EffectRenderContext,
        resources: MetalFrameResources
    ) throws -> EffectRenderResult {
        EffectRenderResult(image: image)
    }
}

@Suite(.serialized)
struct CanvasAndRenderingTests {
    @Test(arguments: [1.0, 0.45])
    func chainedDistortionsMatchSeparateRasterization(mix: Double) throws {
        let bounds = CGRect(x: -13, y: 19, width: 64, height: 48)
        let backdrop = CIImage(color: CIColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 0.6))
            .cropped(to: bounds)
        let foreground = CIImage(color: CIColor(red: 0.9, green: 0.15, blue: 0.05, alpha: 0.55))
            .cropped(to: bounds.insetBy(dx: 11, dy: 7).offsetBy(dx: 4, dy: -3))
        let input = foreground.composited(over: backdrop)
        let registry = try EffectRenderRegistry(modules: [
            SpatialEffectRenderer(moduleID: .waveWarp, kind: .waveWarp),
            SpatialEffectRenderer(moduleID: .displacementMap, kind: .displacementMap),
            DistortionTextureBarrier(),
        ])
        let renderer = try MetalFrameRenderer(effectRegistry: registry)
        var warp = try #require(EffectRegistry.shared.makeEffect(moduleID: .waveWarp))
        warp.mix = AnimatableProperty(baseValue: mix)
        let displacement = try #require(EffectRegistry.shared.makeEffect(moduleID: .displacementMap))
        var barrier = try #require(EffectRegistry.shared.makeEffect(moduleID: .sepia))
        barrier.mix = AnimatableProperty(baseValue: 1)
        let context = CIContext()

        func pixels(_ effects: [EffectInstance]) throws -> Data {
            let image = try renderer.renderEffectsSynchronously(
                EffectStack(effects: effects), to: input, at: 0.4, renderScale: 1
            )
            let bytesPerRow = Int(bounds.width) * 4
            var data = Data(count: bytesPerRow * Int(bounds.height))
            data.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: bytesPerRow, bounds: bounds,
                    format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
            return data
        }

        #expect(try pixels([warp, displacement]) == pixels([warp, barrier, displacement]))
    }

    @Test(arguments: [1.0, 0.45])
    func unfoldedEffectChainsStayInsideObjectBounds(mix: Double) throws {
        let bounds = CGRect(x: 13, y: 19, width: 64, height: 48)
        let input = CIImage(color: .white).cropped(to: bounds)
        let renderer = try MetalFrameRenderer()
        var effects: [EffectInstance] = []
        for moduleID in [EffectModuleID.analogGlitch, .prismSplit, .chromaticAberration, .zoomBlur] {
            var effect = try #require(EffectRegistry.shared.makeEffect(moduleID: moduleID))
            effect.mix = AnimatableProperty(baseValue: mix)
            effects.append(effect)
            let output = try renderer.renderEffectsSynchronously(
                EffectStack(effects: effects), to: input, at: 0.4, renderScale: 1
            )
            #expect(output.extent == bounds)
            let inspectedBounds = bounds.insetBy(dx: -4, dy: -4)
            let width = Int(inspectedBounds.width)
            let height = Int(inspectedBounds.height)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            CIContext().render(output, toBitmap: &pixels, rowBytes: width * 4,
                               bounds: inspectedBounds, format: .RGBA8,
                               colorSpace: CGColorSpaceCreateDeviceRGB())
            for y in 0..<height {
                for x in 0..<width {
                    let inside = x >= 4 && x < width - 4 && y >= 4 && y < height - 4
                    let alpha = pixels[(y * width + x) * 4 + 3]
                    #expect(inside ? alpha >= 250 : alpha == 0,
                            "\(moduleID.rawValue), mix \(mix), pixel (\(x), \(y)): alpha \(alpha)")
                }
            }
        }
    }

    @Test(arguments: [EffectModuleID.directionalBlur, .zoomBlur])
    func opticalBlursProduceVisibleOpaquePixels(moduleID: EffectModuleID) throws {
        let bounds = CGRect(x: 13, y: 19, width: 64, height: 64)
        let input = CIImage(color: .white)
            .cropped(to: CGRect(x: 39, y: 19, width: 12, height: 64))
            .composited(over: CIImage(color: .black).cropped(to: bounds))
            .cropped(to: bounds)
        let effect = try #require(EffectRegistry.shared.makeEffect(moduleID: moduleID))
        let renderer = try MetalFrameRenderer()
        let output = try renderer.renderEffectsSynchronously(
            EffectStack(effects: [effect]), to: input, at: 0, renderScale: 1
        )
        let context = CIContext()
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        var original = pixels
        context.render(output, toBitmap: &pixels, rowBytes: 64 * 4,
                       bounds: bounds, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        context.render(input, toBitmap: &original, rowBytes: 64 * 4,
                       bounds: bounds, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        // Allow the optical kernels' small rounding error in accumulated alpha.
        #expect(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] >= 250 })
        let difference = zip(pixels, original).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        #expect(difference > 1000, "The blur must visibly change the source image")
    }

    @Test func completedRenderRequestsReleaseTimeoutCapturesImmediately() {
        let finisher = MotionaryVideoCompositor.RequestFinisher()
        weak var capturedObject: NSObject?
        do {
            let object = NSObject()
            capturedObject = object
            finisher.setTimeoutAction { _ = object.description }
        }
        #expect(capturedObject != nil)
        #expect(finisher.finish {})
        #expect(capturedObject == nil)
        finisher.timeOut()
        #expect(!finisher.finish {})
    }

    @MainActor
    @Test(arguments: [false, true], [EffectModuleID.cinematicBloom, .analogGlitch, .fineGrain])
    func renderedSpatialEffectsMatchProjectPixelsAtDifferentResolutions(onAdjustmentLayer: Bool, moduleID: EffectModuleID) throws {
        let effects = try [moduleID].map {
            try #require(EffectRegistry.shared.makeEffect(moduleID: $0))
        }
        let stack = EffectStack(effects: effects)
        func descriptor(shape: ClipShape?, stack: EffectStack, adjustment: Bool) -> RenderClipDescriptor {
            RenderClipDescriptor(
                trackID: kCMPersistentTrackID_Invalid,
                backgroundMaskTrackID: nil,
                clipID: UUID(),
                timelineStart: 0,
                duration: 1,
                sourceTransform: .identity,
                backgroundMaskSourceTransform: .identity,
                transform: ClipTransform(),
                adjustments: AdjustmentSettings(),
                effectStack: stack,
                mask: nil,
                backgroundRemoval: nil,
                blendMode: .normal,
                blendIntensity: 1,
                shape: shape,
                text: nil,
                role: adjustment ? .adjustment : .content,
                renderOrder: adjustment ? 1 : 0
            )
        }
        let shape = ClipShape(kind: .rectangle, color: .white, width: 32, height: 24)
        var clips = [descriptor(shape: shape, stack: onAdjustmentLayer ? EffectStack() : stack, adjustment: false)]
        if onAdjustmentLayer {
            clips.append(descriptor(shape: nil, stack: stack, adjustment: true))
        }
        let renderer = try MetalFrameRenderer()
        let context = CIContext()
        var reference: CIImage?
        for dimension in [64, 64, 128, 64, 256, 64] {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, dimension, dimension, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferMetalCompatibilityKey: true,
                 kCVPixelBufferIOSurfacePropertiesKey: [String: String]()] as CFDictionary,
                &buffer
            )
            #expect(status == kCVReturnSuccess)
            let destination = try #require(buffer)
            try renderer.render(
                plan: FrameRenderPlan(
                    renderSize: CGSize(width: dimension, height: dimension),
                    renderScale: CGFloat(dimension) / 64,
                    backgroundColor: .black,
                    frameDuration: 1 / 30,
                    clips: clips,
                    quality: .export,
                    failurePolicy: .failOnUnavailableEffects
                ),
                compositionTime: .zero,
                sourceFrame: { _ in nil },
                destination: destination,
                isCancelled: { false }
            )
            let actual = CIImage(cvPixelBuffer: destination)
            if let reference {
                let scale = CGFloat(dimension) / 64
                let expected = reference.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let bounds = CGRect(x: 0, y: 0, width: dimension, height: dimension)
                var pixels = [UInt8](repeating: 0, count: dimension * dimension * 4)
                var expectedPixels = pixels
                context.render(actual, toBitmap: &pixels, rowBytes: dimension * 4,
                               bounds: bounds, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                context.render(expected, toBitmap: &expectedPixels, rowBytes: dimension * 4,
                               bounds: bounds, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                let error = zip(expectedPixels, pixels).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
                    / Double(pixels.count)
                #expect(error < 4, "Rendered effect appearance changed at \(dimension)px: mean error \(error)")
            } else {
                reference = actual
            }
        }
    }

    @MainActor
    @Test(arguments: [720, 1080, 2160])
    func effectStackExportsAtHDAnd4K(height: Int) async throws {
        let effects = try [EffectModuleID.cinematicBloom, .analogGlitch, .fineGrain].map {
            try #require(EffectRegistry.shared.makeEffect(moduleID: $0))
        }
        let shape = ShapeTimelineItem(
            name: "Export regression",
            mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle, color: .white, width: 140, height: 80),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 1),
            visuals: TimelineItemVisuals(effectStack: EffectStack(effects: effects))
        )
        let project = EditorProject(
            title: "Effect export regression",
            renderSettings: RenderSettings(width: 320, height: 180, frameRate: 10),
            tracks: [TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])]
        )
        let width = height * 16 / 9
        let settings = VideoExportSettings(
            width: width, height: height, frameRate: 10,
            videoBitrate: 8_000_000, audioBitrate: 96_000,
            codec: .h264, container: .mp4
        )
        let url = try await VideoExportService().export(project: project, settings: settings, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == width)
        #expect(Int(size.height) == height)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 320, height: 180)
        let frame = try await generator.image(at: .zero).image
        let pixel = try rgbaPixel(in: frame, x: frame.width / 2, y: frame.height / 2)
        #expect(pixel[0] > 100 && pixel[1] > 100 && pixel[2] > 100)
    }

    @MainActor
    @Test func highFrameRateExportPreservesTimelineSpeed() async throws {
        let shape = ShapeTimelineItem(
            name: "Timing", mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle, color: .white, width: 96, height: 96),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 1),
            visuals: TimelineItemVisuals(transform: ClipTransform(
                opacity: AnimatableProperty(baseValue: 0, keyframes: [
                    Keyframe(time: 0, value: 0), Keyframe(time: 1, value: 1)
                ])
            ))
        )
        let project = EditorProject(title: "Timing", renderSettings: RenderSettings(
            width: 96, height: 96, frameRate: 60
        ), tracks: [TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])])
        let settings = VideoExportSettings(width: 96, height: 96, frameRate: 120,
            videoBitrate: 1_000_000, audioBitrate: 96_000, codec: .h264, container: .mp4)
        let url = try await VideoExportService().export(project: project, settings: settings, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(abs(Double(try await track.load(.nominalFrameRate)) - 120) < 0.1)
        #expect(abs(CMTimeGetSeconds(try await asset.load(.duration)) - 1) < 0.02)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        #expect(reader.startReading())
        var count = 0
        var lastTime = -1.0
        while let sample = output.copyNextSampleBuffer() {
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            #expect(abs(time - Double(count) / 120) < 0.001)
            lastTime = time
            count += 1
        }
        #expect(reader.status == .completed)
        #expect(count == 120)
        #expect(lastTime > 0.98)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let early = try await generator.image(at: CMTime(seconds: 0.25, preferredTimescale: 600)).image
        let late = try await generator.image(at: CMTime(seconds: 0.75, preferredTimescale: 600)).image
        let earlyPixel = try rgbaPixel(in: early, x: 48, y: 48)
        let latePixel = try rgbaPixel(in: late, x: 48, y: 48)
        #expect(latePixel[0] > earlyPixel[0] + 50)
        #expect(latePixel[0] > 150)
    }

    @Test func photosRejectionPreservesTheCompletedVideo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("export.mp4")
        let data = Data([1, 2, 3, 4])
        try data.write(to: input)
        let saved = try PhotoLibraryExportService.preserveVideo(at: input, directory: folder.appendingPathComponent("saved"))
        try FileManager.default.removeItem(at: input)
        #expect(try Data(contentsOf: saved) == data)
        #expect(saved.pathExtension == "mp4")
    }

    @MainActor
    @Test(arguments: [false, true])
    func encodedExportBrightnessDoesNotChangeWithResolution(withGlitch: Bool) async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128), format: format).image { context in
            for (index, gray) in [0.18, 0.35, 0.55, 0.75].enumerated() {
                UIColor(white: gray, alpha: 1).setFill()
                context.fill(CGRect(x: (index % 2) * 64, y: (index / 2) * 64, width: 64, height: 64))
            }
        }
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try #require(image.pngData()).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let source = ClipSource(url: input, mediaType: .image, originalDuration: 0.3,
                                naturalSize: CGSizeValue(width: 128, height: 128))
        let clip = TimelineClip(name: "Gray values", source: source, timelineStart: 0,
                                sourceRange: TimeRangeValue(start: 0, duration: 0.3))
        var tracks = [TimelineTrack(name: "Image", kind: .visual, clips: [clip])]
        if withGlitch {
            let effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .analogGlitch))
            let adjustment = AdjustmentTimelineItem(timelineStart: 0, duration: 0.3,
                visuals: TimelineItemVisuals(effectStack: EffectStack(effects: [effect])))
            tracks.insert(TimelineTrack(name: "Glitch", kind: .visual, items: [.adjustment(adjustment)]), at: 0)
        }
        let project = EditorProject(title: "Brightness", renderSettings: RenderSettings(width: 128, height: 128, frameRate: 10), tracks: tracks)
        var reference: [[UInt8]]?
        for dimension in [128, 64, 256, 512] {
            let settings = VideoExportSettings(width: dimension, height: dimension, frameRate: 10,
                videoBitrate: 8_000_000, audioBitrate: 96_000, codec: .h264, container: .mp4)
            let url = try await VideoExportService().export(project: project, settings: settings, progress: { _ in })
            defer { try? FileManager.default.removeItem(at: url) }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            let frame = try await generator.image(at: .zero).image
            let samples = try [(1, 1), (3, 1), (1, 3), (3, 3)].map { x, y in
                try rgbaPixel(in: frame, x: frame.width * x / 4, y: frame.height * y / 4)
            }
            if let reference {
                for (expected, actual) in zip(reference, samples) {
                    for channel in 0..<3 {
                        #expect(abs(Int(expected[channel]) - Int(actual[channel])) <= 5,
                                "Brightness changed at \(dimension)px: \(reference) -> \(samples)")
                    }
                }
            } else { reference = samples }
        }
    }

    @Test func mediaEffectsStayInSourcePixelsAcrossOutputResolutions() {
        for outputScale: CGFloat in [0.5, 1, 2, 4] {
            let coordinates = LayerEffectCoordinates(
                isGeneratedLayer: false,
                outputScale: outputScale,
                rasterScaleCorrection: CGSize(width: 1, height: 1)
            )
            #expect(coordinates.renderScale == 1)
            #expect(coordinates.inputTransform == .identity)
        }
    }

    @Test func generatedEffectRadiusSurvivesOutputAndNonUniformRasterScaling() {
        for outputScale: CGFloat in [0.5, 1, 2] {
            let correction = CGSize(width: 0.25, height: 0.5)
            let coordinates = LayerEffectCoordinates(
                isGeneratedLayer: true,
                outputScale: outputScale,
                rasterScaleCorrection: correction
            )
            let radius = 36 * coordinates.renderScale
            let restored = CGSize(width: radius, height: radius)
                .applying(coordinates.inputTransform.inverted())
            #expect(restored.width * correction.width / outputScale == 36)
            #expect(restored.height * correction.height / outputScale == 36)
        }
    }

    @Test func canvasPositionSnappingUsesReleaseHysteresis() {
        let targets = PreviewSnapTargets(x: [100], y: [])
        let acquired = PreviewSnapEngine.position(
            center: CGPoint(x: 93, y: 40),
            anchorOffsets: [.zero],
            targets: targets,
            lockedX: nil,
            lockedY: nil
        )
        let retained = PreviewSnapEngine.position(
            center: CGPoint(x: 112, y: 40),
            anchorOffsets: [.zero],
            targets: targets,
            lockedX: acquired.lockX,
            lockedY: nil
        )
        let released = PreviewSnapEngine.position(
            center: CGPoint(x: 116, y: 40),
            anchorOffsets: [.zero],
            targets: targets,
            lockedX: retained.lockX,
            lockedY: nil
        )

        #expect(acquired.center.x == 100)
        #expect(acquired.guideX == 100)
        #expect(retained.center.x == 100)
        #expect(retained.guideX == 100)
        #expect(released.center.x == 116)
        #expect(released.guideX == nil)
    }

    @Test func canvasScaleSnappingUsesTheSameStableGuideForPinchAndHandle() {
        let targets = PreviewSnapTargets(x: [200], y: [])
        let acquired = PreviewSnapEngine.scale(
            center: CGPoint(x: 100, y: 100),
            baseAnchorOffsets: [CGPoint(x: 50, y: 0)],
            proposedScale: 1.84,
            targets: targets,
            lockedX: nil,
            lockedY: nil,
            minimumScale: 0.05,
            maximumScale: 100,
            maximumSnapRatio: 1.35
        )
        let retained = PreviewSnapEngine.scale(
            center: CGPoint(x: 100, y: 100),
            baseAnchorOffsets: [CGPoint(x: 50, y: 0)],
            proposedScale: 2.2,
            targets: targets,
            lockedX: acquired.lockX,
            lockedY: nil,
            minimumScale: 0.05,
            maximumScale: 100,
            maximumSnapRatio: 1.35
        )
        let unsnappedWithoutLock = PreviewSnapEngine.scale(
            center: CGPoint(x: 100, y: 100),
            baseAnchorOffsets: [CGPoint(x: 50, y: 0)],
            proposedScale: 2.2,
            targets: targets,
            lockedX: nil,
            lockedY: nil,
            minimumScale: 0.05,
            maximumScale: 100,
            maximumSnapRatio: 1.35
        )

        #expect(abs(acquired.scale - 2) < 0.000_001)
        #expect(acquired.guideX == 200)
        #expect(abs(retained.scale - 2) < 0.000_001)
        #expect(retained.guideX == 200)
        #expect(abs(unsnappedWithoutLock.scale - 2.2) < 0.000_001)
        #expect(unsnappedWithoutLock.guideX == nil)
    }

    @Test func canvasPositionHysteresisKeepsTheAcquiredAnchorIdentity() {
        let targets = PreviewSnapTargets(x: [100], y: [])
        let acquired = PreviewSnapEngine.position(
            center: CGPoint(x: 94.9, y: 40),
            anchorOffsets: [.zero, CGPoint(x: 10, y: 0)],
            targets: targets,
            lockedX: nil,
            lockedY: nil
        )
        let retained = PreviewSnapEngine.position(
            center: CGPoint(x: 95.1, y: 40),
            anchorOffsets: [.zero, CGPoint(x: 10, y: 0)],
            targets: targets,
            lockedX: acquired.lockX,
            lockedY: nil
        )

        #expect(acquired.lockX?.anchorIndex == 1)
        #expect(abs(acquired.center.x - 90) < 0.000_001)
        #expect(retained.lockX?.anchorIndex == 1)
        #expect(abs(retained.center.x - 90) < 0.000_001)
    }

    @Test func canvasScaleHysteresisKeepsTheAcquiredAnchorIdentity() {
        let targets = PreviewSnapTargets(x: [100], y: [])
        let acquired = PreviewSnapEngine.scale(
            center: .zero,
            baseAnchorOffsets: [
                CGPoint(x: 50, y: 0),
                CGPoint(x: 60, y: 0),
            ],
            proposedScale: 1.7,
            targets: targets,
            lockedX: nil,
            lockedY: nil,
            minimumScale: 0.05,
            maximumScale: 100,
            maximumSnapRatio: 1.35
        )
        let retained = PreviewSnapEngine.scale(
            center: .zero,
            baseAnchorOffsets: [
                CGPoint(x: 50, y: 0),
                CGPoint(x: 60, y: 0),
            ],
            proposedScale: 1.82,
            targets: targets,
            lockedX: acquired.lockX,
            lockedY: nil,
            minimumScale: 0.05,
            maximumScale: 100,
            maximumSnapRatio: 1.35
        )

        #expect(acquired.lockX?.anchorIndex == 1)
        #expect(abs(acquired.scale - (100 / 60)) < 0.000_001)
        #expect(retained.lockX?.anchorIndex == 1)
        #expect(abs(retained.scale - (100 / 60)) < 0.000_001)
    }

    @Test func canvasRotationSnappingRetainsThenReleasesWithoutJitter() {
        let acquired = PreviewSnapEngine.rotation(
            degrees: 1.5,
            lockedGuideDegrees: nil
        )
        let retained = PreviewSnapEngine.rotation(
            degrees: 3.8,
            lockedGuideDegrees: acquired.guideDegrees
        )
        let released = PreviewSnapEngine.rotation(
            degrees: 5,
            lockedGuideDegrees: retained.guideDegrees
        )

        #expect(acquired.degrees == 0)
        #expect(acquired.didSnap)
        #expect(retained.degrees == 0)
        #expect(retained.didSnap)
        #expect(released.degrees == 5)
        #expect(!released.didSnap)
    }

    @Test func canvasHitSelectionUsesLayerStackForOverlappingFullCanvasLayers() {
        let topAdjustmentID = UUID()
        let contentID = UUID()
        let bottomAdjustmentID = UUID()

        let selected = PreviewHitResolver.topmost(
            in: [
                PreviewHitLayer(id: contentID, stackOrder: 1),
                PreviewHitLayer(id: bottomAdjustmentID, stackOrder: 2),
                PreviewHitLayer(id: topAdjustmentID, stackOrder: 0),
            ]
        )

        #expect(selected == topAdjustmentID)
    }

    @Test func fullCanvasAdjustmentHitRegionOnlyConsumesItsBorder() {
        let frame = PreviewClipFrame(
            rect: CGRect(x: 0, y: 0, width: 320, height: 180),
            rotationDegrees: 0
        )

        #expect(frame.contains(CGPoint(x: 160, y: 90)))
        #expect(!frame.containsBorder(CGPoint(x: 160, y: 90), tolerance: 18))
        #expect(frame.containsBorder(CGPoint(x: 7, y: 90), tolerance: 18))
        #expect(frame.containsBorder(CGPoint(x: 160, y: 174), tolerance: 18))
    }

    @Test func canvasVisualIntervalIndexUsesHalfOpenRangesAndStableStackOrder() {
        let clip = TimelineClip(
            name: "Video",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/index-video.mov"),
                mediaType: .video,
                originalDuration: 1
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        let text = TextTimelineItem(
            text: "Text",
            timelineStart: 1,
            duration: 1
        )
        let adjustment = AdjustmentTimelineItem(
            timelineStart: 0.5,
            duration: 1
        )
        let audio = TimelineClip(
            name: "Audio",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/index-audio.m4a"),
                mediaType: .audio,
                originalDuration: 10
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 10)
        )
        let project = EditorProject(
            title: "Canvas interval index",
            tracks: [
                TimelineTrack(name: "Video", kind: .visual, clips: [clip]),
                TimelineTrack(name: "Text", kind: .text, items: [.text(text)]),
                TimelineTrack(
                    name: "Adjustment",
                    kind: .visual,
                    items: [.adjustment(adjustment)]
                ),
                TimelineTrack(name: "Audio", kind: .audio, clips: [audio]),
            ]
        )
        let index = PreviewVisualIntervalIndex(project: project)

        #expect(index.active(at: 0.75, retaining: nil).map(\.id) == [
            clip.id,
            adjustment.id,
        ])
        #expect(index.active(at: 1, retaining: nil).map(\.id) == [
            text.id,
            adjustment.id,
        ])
        #expect(index.active(at: 1, retaining: clip.id).map(\.id) == [
            clip.id,
            text.id,
            adjustment.id,
        ])
    }

    @Test func liveCanvasProxyNeverDropsEnabledEffectsOrMasks() {
        let plain = TimelineItemVisuals()
        let effected = TimelineItemVisuals(
            effectStack: EffectStack(
                effects: [
                    EffectInstance(moduleID: "test.canvas.effect")
                ]
            )
        )
        let disabledEffect = TimelineItemVisuals(
            effectStack: EffectStack(
                effects: [
                    EffectInstance(
                        moduleID: "test.canvas.effect",
                        isEnabled: false
                    )
                ]
            )
        )
        let masked = TimelineItemVisuals(mask: ItemMask())

        #expect(PreviewInteractionProxyPolicy.canUseRasterProxy(for: plain))
        #expect(!PreviewInteractionProxyPolicy.canUseRasterProxy(for: effected))
        #expect(PreviewInteractionProxyPolicy.canUseRasterProxy(for: disabledEffect))
        #expect(!PreviewInteractionProxyPolicy.canUseRasterProxy(for: masked))
    }

    @Test func staleCanvasRasterRequestsCannotReplaceTheCurrentSelection() {
        let selectedID = UUID()
        let loadID = UUID()
        let token = PreviewRasterRequestToken(
            itemID: selectedID,
            assetKey: "selected|revision|time",
            loadID: loadID
        )

        #expect(
            PreviewRasterDeliveryPolicy.shouldApply(
                token,
                currentLoadID: loadID,
                currentSelectedItemID: selectedID,
                currentAssetKey: token.assetKey,
                isTransforming: false
            )
        )
        #expect(
            !PreviewRasterDeliveryPolicy.shouldApply(
                token,
                currentLoadID: UUID(),
                currentSelectedItemID: selectedID,
                currentAssetKey: token.assetKey,
                isTransforming: false
            )
        )
        #expect(
            !PreviewRasterDeliveryPolicy.shouldApply(
                token,
                currentLoadID: loadID,
                currentSelectedItemID: UUID(),
                currentAssetKey: token.assetKey,
                isTransforming: false
            )
        )
        #expect(
            !PreviewRasterDeliveryPolicy.shouldApply(
                token,
                currentLoadID: loadID,
                currentSelectedItemID: selectedID,
                currentAssetKey: "newer-frame",
                isTransforming: false
            )
        )
        #expect(
            !PreviewRasterDeliveryPolicy.shouldApply(
                token,
                currentLoadID: loadID,
                currentSelectedItemID: selectedID,
                currentAssetKey: token.assetKey,
                isTransforming: true
            )
        )
    }

    @Test func adjustmentCanvasGeometryDefaultsToFullCanvasBounds() {
        let canvas = CGRect(x: 0, y: 0, width: 320, height: 180)
        let mapper = PreviewGeometryMapper(
            canvasRect: canvas,
            renderSize: CGSize(width: 1_920, height: 1_080)
        )

        let identity = mapper.adjustmentFrame(transform: ClipTransform(), at: 0)
        var transformed = ClipTransform()
        transformed.positionX.baseValue = 0.25
        transformed.positionY.baseValue = -0.5
        transformed.scale.baseValue = ScaleValue(x: 0.5, y: 2)
        transformed.rotationDegrees.baseValue = 30
        let edited = mapper.adjustmentFrame(transform: transformed, at: 0)

        #expect(identity.rect == canvas)
        #expect(identity.rotationDegrees == 0)
        #expect(edited.rect.size == CGSize(width: 160, height: 360))
        #expect(edited.center == CGPoint(x: 200, y: 135))
        #expect(edited.rotationDegrees == 30)
    }

    @MainActor
    @Test func adjustmentCanvasTransformEditsItsOwnVisualModel() throws {
        let adjustment = AdjustmentTimelineItem(
            timelineStart: 0,
            duration: 3
        )
        let project = EditorProject(
            title: "Adjustment canvas transform",
            tracks: [
                TimelineTrack(
                    name: "Adjustment",
                    kind: .visual,
                    items: [.adjustment(adjustment)]
                )
            ]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.selectTimelineItem(
            adjustment.id,
            trackID: project.tracks[0].id
        )
        viewModel.currentTime = 1

        viewModel.setSelectedAdjustmentTransform(
            positionX: 0.25,
            positionY: -0.4,
            scale: ScaleValue(x: 1.5, y: 0.75),
            rotationDegrees: 30
        )

        let updated = try #require(viewModel.project.item(id: adjustment.id))
        guard case .adjustment(let item) = updated else {
            Issue.record("Canvas transform converted the adjustment into another layer kind")
            return
        }
        #expect(item.visuals.transform.positionX.baseValue == 0.25)
        #expect(item.visuals.transform.positionY.baseValue == -0.4)
        #expect(item.visuals.transform.scale.baseValue == ScaleValue(x: 1.5, y: 0.75))
        #expect(item.visuals.transform.rotationDegrees.baseValue == 30)
        #expect(viewModel.project.tracks[0].items[0].kind == .adjustment)
    }

    @MainActor
    @Test func interactiveAdjustmentTransformPublishesNewKeyframeSnapshotOnCommit() throws {
        let adjustment = AdjustmentTimelineItem(
            timelineStart: 0,
            duration: 3,
            visuals: TimelineItemVisuals(
                transform: ClipTransform(
                    positionX: AnimatableProperty(
                        baseValue: 0,
                        keyframes: [Keyframe(time: 0, value: 0)]
                    )
                )
            )
        )
        let track = TimelineTrack(
            name: "Adjustment",
            kind: .visual,
            items: [.adjustment(adjustment)]
        )
        let project = EditorProject(
            title: "Adjustment keyframe invalidation",
            tracks: [track]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.selectTimelineItem(adjustment.id, trackID: track.id)
        viewModel.currentTime = 1
        let initialSnapshot = viewModel.timelineRenderSnapshot

        viewModel.setSelectedAdjustmentTransform(
            positionX: 0.5,
            interactive: true
        )

        #expect(
            viewModel.timelineRenderSnapshot.trackSnapshotsByID[track.id]?
                .items.first?.keyframeTimes == [0]
        )

        viewModel.finishInteractiveEdit(rebuild: false)
        let committedSnapshot = viewModel.timelineRenderSnapshot

        #expect(committedSnapshot.revision > initialSnapshot.revision)
        #expect(
            committedSnapshot.trackSnapshotsByID[track.id]?
                .items.first?.keyframeTimes == [0, 1]
        )
        let committedItem = try #require(
            viewModel.project.item(id: adjustment.id)
        )
        guard case .adjustment(let committed) = committedItem else {
            Issue.record("Expected adjustment layer after interactive transform")
            return
        }
        #expect(committed.visuals.transform.positionX.keyframes.map(\.time) == [0, 1])
    }

    @Test func editorUnitsScaleTheLongestDimensionToOneThousand() {
        let landscape = EditorUnitSpace(size: CGSize(width: 2_000, height: 1_000))
        let square = EditorUnitSpace(size: CGSize(width: 800, height: 800))

        #expect(landscape.width == 1_000)
        #expect(landscape.height == 500)
        #expect(square.width == 1_000)
        #expect(square.height == 1_000)
    }

    @Test func textBoxWidthActsAsAMaximumForShortText() {
        let compact = TextTimelineItem(
            text: "Short",
            layout: TextLayout(widthFraction: 0.4),
            timelineStart: 0,
            duration: 1
        )
        let generous = TextTimelineItem(
            text: "Short",
            layout: TextLayout(widthFraction: 0.9),
            timelineStart: 0,
            duration: 1
        )
        let renderSize = CGSize(width: 1_000, height: 1_000)
        let compactGeometry = TextLayerRenderer.geometry(
            for: compact,
            renderSize: renderSize,
            renderScale: 1
        )
        let generousGeometry = TextLayerRenderer.geometry(
            for: generous,
            renderSize: renderSize,
            renderScale: 1
        )

        #expect(abs(compactGeometry.layerSize.width - generousGeometry.layerSize.width) < 1)
        #expect(generousGeometry.layerSize.width < renderSize.width * 0.9)
    }

    @Test func textSupersamplingPreservesLogicalGeometry() {
        let item = TextTimelineItem(
            text: "This multiline text should keep the same wrapping when supersampled.",
            style: TextStyle(fontSize: 42),
            layout: TextLayout(widthFraction: 0.42),
            timelineStart: 0,
            duration: 1
        )
        let renderSize = CGSize(width: 640, height: 360)
        let renderer = TextLayerRenderer()
        let preparedSample = renderer.prepareSample(
            item: item,
            renderSize: renderSize,
            renderScale: 0.5,
            at: 0.25
        )
        let base = renderer.render(
            preparedSample,
            rasterScaleMultiplier: 1
        )
        let supersampled = renderer.render(
            preparedSample,
            rasterScaleMultiplier: 2
        )

        #expect(preparedSample.geometry == base.geometry)
        #expect(base.geometry == supersampled.geometry)
        #expect(renderer.layoutPreparationCount == 1)
        #expect(renderer.layoutKeyCreationCount == 1)
        #expect(renderer.itemResolutionCount == 1)
        #expect(renderer.rasterKeyCreationCount == 2)
        #expect(abs(supersampled.image.extent.width - base.image.extent.width * 2) <= 1)
        #expect(abs(supersampled.image.extent.height - base.image.extent.height * 2) <= 1)
    }

    @Test func textRasterIdentityIsStableOnlyForTheCachedRasterLifetime() {
        let item = TextTimelineItem(
            text: "Stable GPU cache identity",
            style: TextStyle(fontSize: 42),
            timelineStart: 0,
            duration: 1
        )
        let renderer = TextLayerRenderer()
        let first = renderer.render(
            item: item,
            renderSize: CGSize(width: 640, height: 360),
            renderScale: 1
        )
        let cached = renderer.render(
            item: item,
            renderSize: CGSize(width: 640, height: 360),
            renderScale: 1
        )

        #expect(cached.cacheIdentity == first.cacheIdentity)

        renderer.removeAllObjects()
        let rerasterized = renderer.render(
            item: item,
            renderSize: CGSize(width: 640, height: 360),
            renderScale: 1
        )

        #expect(rerasterized.cacheIdentity != first.cacheIdentity)
    }

    @MainActor
    @Test func frameRendererEncodesGeneratedCacheMissesWithoutStandaloneGPUWaits() throws {
        let text = TextTimelineItem(
            text: "One prepared frame sample",
            timelineStart: 0,
            duration: 1
        )
        let shape = ClipShape(
            kind: .rectangle,
            color: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1),
            width: 80,
            height: 80
        )
        let stillImage = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let stillURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-preview-still.png")
        try #require(stillImage.pngData()).write(to: stillURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: stillURL) }

        let shapeDescriptor = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: UUID(),
            timelineStart: 0,
            duration: 1,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(),
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(),
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: shape,
            text: nil,
            renderOrder: 0
        )
        let stillDescriptor = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            stillImageURL: stillURL,
            clipID: UUID(),
            timelineStart: 0,
            duration: 1,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(),
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(),
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: nil,
            text: nil,
            renderOrder: 1
        )
        let textDescriptor = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: text.id,
            timelineStart: 0,
            duration: 1,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: text.visuals.transform,
            adjustments: text.visuals.adjustments,
            effectStack: text.visuals.effectStack,
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: nil,
            text: text,
            renderOrder: 2
        )
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            320,
            180,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: String]()
            ] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let renderer = try MetalFrameRenderer()
        let plan = FrameRenderPlan(
            renderSize: CGSize(width: 320, height: 180),
            renderScale: 1,
            backgroundColor: .black,
            frameDuration: 1 / 60,
            clips: [shapeDescriptor, stillDescriptor, textDescriptor],
            quality: .interactive,
            failurePolicy: .failOnUnavailableEffects
        )
        try renderer.render(
            plan: plan,
            compositionTime: CMTime(seconds: 0.2, preferredTimescale: 600),
            sourceFrame: { _ in nil },
            destination: try #require(pixelBuffer),
            isCancelled: { false }
        )
        let firstFrameAverage = averageRGBA(in: try #require(pixelBuffer))
        #expect(firstFrameAverage[0] > 2)
        #expect(firstFrameAverage[1] > 2)
        #expect(firstFrameAverage[2] > 2)

        let metrics = renderer.textPreparationMetrics()
        #expect(metrics.itemResolutions == 1)
        #expect(metrics.layoutKeyCreations == 1)
        #expect(metrics.layoutPreparations == 1)
        #expect(metrics.rasterKeyCreations == 1)
        #expect(metrics.inFrameTextureUploads == 1)
        #expect(metrics.standaloneTextureUploadSubmissions == 0)

        // A completed frame publishes the immutable texture cache entry. The
        // next frame must reuse it without either another in-frame upload or
        // falling back to a synchronously waited standalone command buffer.
        try renderer.render(
            plan: plan,
            compositionTime: CMTime(seconds: 0.2, preferredTimescale: 600),
            sourceFrame: { _ in nil },
            destination: try #require(pixelBuffer),
            isCancelled: { false }
        )
        let cachedFrameAverage = averageRGBA(in: try #require(pixelBuffer))
        #expect(zip(firstFrameAverage, cachedFrameAverage).allSatisfy { pair in
            abs(Int(pair.0) - Int(pair.1)) <= 1
        })
        let cachedMetrics = renderer.textPreparationMetrics()
        #expect(cachedMetrics.inFrameTextureUploads == 1)
        #expect(cachedMetrics.standaloneTextureUploadSubmissions == 0)
    }

    @Test func roundedRectangleSupersamplingScalesCornerRadiusAfterLogicalClamp() {
        let shape = ClipShape(
            kind: .roundedRectangle,
            color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
            width: 120,
            height: 40,
            cornerRadius: 64
        )
        let base = ShapeRasterLayout(
            shape: shape,
            at: 0,
            logicalRenderScale: 0.5,
            rasterScaleMultiplier: 1
        )
        let supersampled = ShapeRasterLayout(
            shape: shape,
            at: 0,
            logicalRenderScale: 0.5,
            rasterScaleMultiplier: 2
        )

        #expect(base.logicalSize == CGSize(width: 60, height: 20))
        #expect(base.logicalCornerRadius == 10)
        #expect(supersampled.logicalSize == base.logicalSize)
        #expect(supersampled.logicalCornerRadius == base.logicalCornerRadius)
        #expect(supersampled.rasterSize == CGSize(width: 120, height: 40))
        #expect(supersampled.rasterCornerRadius == 20)
    }

    @Test func shapeRasterPolicyCachesStaticInteractiveShapes() {
        let staticShape = ClipShape(
            kind: .rectangle,
            color: .white,
            width: 100,
            height: 60
        )
        #expect(
            !ShapeRasterizationPolicy.requiresFrameLocalEncoding(
                shape: staticShape,
                transform: ClipTransform(),
                hasTransientScaleOverride: false
            )
        )

        var positionOnlyTransform = ClipTransform()
        positionOnlyTransform.positionX.baseValue = 0.4
        #expect(
            !ShapeRasterizationPolicy.requiresFrameLocalEncoding(
                shape: staticShape,
                transform: positionOnlyTransform,
                hasTransientScaleOverride: false
            )
        )
        #expect(
            ShapeRasterizationPolicy.requiresFrameLocalEncoding(
                shape: staticShape,
                transform: positionOnlyTransform,
                hasTransientScaleOverride: true
            )
        )

        var animatedShape = ClipShape(
            kind: .rectangle,
            color: .white,
            width: 100,
            height: 60
        )
        animatedShape.width = AnimatableProperty(
            baseValue: 100,
            keyframes: [Keyframe(time: 0.5, value: 160)]
        )
        #expect(
            ShapeRasterizationPolicy.requiresFrameLocalEncoding(
                shape: animatedShape,
                transform: ClipTransform(),
                hasTransientScaleOverride: false
            )
        )

        let descriptor = shapeDescriptor(
            transform: ClipTransform(),
            color: .white,
            renderOrder: 0
        )
        let liveState = LivePreviewRenderState()
        liveState.setTransform(positionOnlyTransform, for: descriptor.clipID)
        let positionResolved = descriptor.resolvingLiveOverride(from: liveState.snapshot())
        #expect(!positionResolved.hasTransientRasterScaleOverride)

        var scaledTransform = positionOnlyTransform
        scaledTransform.scale.baseValue = ScaleValue(x: 1.5, y: 1.5)
        liveState.setTransform(scaledTransform, for: descriptor.clipID)
        let scaleResolved = descriptor.resolvingLiveOverride(from: liveState.snapshot())
        #expect(scaleResolved.hasTransientRasterScaleOverride)
    }

    @Test func generatedLayersKeepRequestedTimesAtEveryPreviewCadence() {
        for fps in [24.0, 30, 60, 120] {
            for time in [1 / fps, 2 / fps, 3 / fps, 0.017] {
                for quality in [RenderQualityProfile.interactive, .balanced, .export] {
                    #expect(GeneratedLayerSamplingPolicy.sourceTime(time,
                        frameDuration: 1 / fps, quality: quality) == time)
                }
            }
        }
    }

    @Test func textRasterBudgetFallbackPreservesLogicalGeometry() {
        let item = TextTimelineItem(
            text: "Budgeted vector text should keep its exact text box.",
            style: TextStyle(fontSize: 96),
            layout: TextLayout(widthFraction: 0.8),
            timelineStart: 0,
            duration: 1
        )
        let renderSize = CGSize(width: 2_048, height: 1_024)
        let renderer = TextLayerRenderer()
        let base = renderer.render(
            item: item,
            renderSize: renderSize,
            renderScale: 1,
            rasterScaleMultiplier: 1
        )
        let capped = renderer.render(
            item: item,
            renderSize: renderSize,
            renderScale: 1,
            rasterScaleMultiplier: 128
        )

        #expect(base.geometry == capped.geometry)
        #expect(capped.image.extent.width <= CGFloat(GeneratedRasterPolicy.maximumTextureDimension))
        #expect(capped.image.extent.height <= CGFloat(GeneratedRasterPolicy.maximumTextureDimension))
    }

    @Test func shapeRasterBudgetFallbackPreservesLogicalGeometry() {
        let shape = ClipShape(
            kind: .roundedRectangle,
            color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
            width: 3_000,
            height: 1_000,
            cornerRadius: 240
        )
        let base = ShapeRasterLayout(
            shape: shape,
            at: 0,
            logicalRenderScale: 1,
            rasterScaleMultiplier: 1
        )
        let capped = ShapeRasterLayout(
            shape: shape,
            at: 0,
            logicalRenderScale: 1,
            rasterScaleMultiplier: 128
        )

        #expect(base.logicalSize == capped.logicalSize)
        #expect(base.logicalCornerRadius == capped.logicalCornerRadius)
        #expect(max(capped.rasterSize.width, capped.rasterSize.height) <= CGFloat(GeneratedRasterPolicy.maximumTextureDimension))
        #expect(capped.rasterScaleMultiplier < 128)
    }

    @Test func generatedRasterPolicyPreparesForFullCanvasCoverage() {
        let logicalSize = CGSize(width: 100, height: 50)
        let renderSize = CGSize(width: 1_000, height: 1_000)
        let rasterScale = GeneratedRasterPolicy.generatedLayerRasterScale(
            transformScale: CGSize(width: 1, height: 1),
            qualityScale: 1,
            logicalSize: logicalSize,
            renderSize: renderSize
        )

        #expect(rasterScale == CGSize(width: 10, height: 20))
    }

    @Test func generatedRasterPolicyKeepsThinLayersSharpOnBothAxes() {
        let logicalSize = CGSize(width: 3_000, height: 10)
        let renderSize = CGSize(width: 3_000, height: 3_000)
        let rasterScale = GeneratedRasterPolicy.generatedLayerRasterScale(
            transformScale: CGSize(width: 1, height: 1),
            qualityScale: 1,
            logicalSize: logicalSize,
            renderSize: renderSize
        )
        let rasterSize = CGSize(
            width: ceil(logicalSize.width * rasterScale.width),
            height: ceil(logicalSize.height * rasterScale.height)
        )

        #expect(rasterScale.width == 1)
        #expect(rasterScale.height == 300)
        #expect(rasterSize == CGSize(width: 3_000, height: 3_000))
    }

    @Test func generatedRasterPolicyCapsExtremeObjectCoverage() {
        let logicalSize = CGSize(width: 2_000, height: 1_000)
        let renderSize = CGSize(width: 1_000, height: 1_000)
        let rasterScale = GeneratedRasterPolicy.generatedLayerRasterScale(
            transformScale: CGSize(width: 200, height: 200),
            qualityScale: 1,
            logicalSize: logicalSize,
            renderSize: renderSize,
            maximumTextureDimension: 64_000
        )
        let rasterSize = CGSize(
            width: ceil(logicalSize.width * rasterScale.width),
            height: ceil(logicalSize.height * rasterScale.height)
        )

        #expect(rasterSize.width <= renderSize.width * GeneratedRasterPolicy.maximumRasterizedCanvasCoverage)
        #expect(rasterSize.height <= renderSize.height * GeneratedRasterPolicy.maximumRasterizedCanvasCoverage)
    }

    @MainActor
    @Test func metalShapeLayerRasterMatchesSharedLayout() throws {
        let shape = ClipShape(
            kind: .roundedRectangle,
            color: RGBAColor(red: 0.2, green: 0.4, blue: 1, alpha: 1),
            width: 100,
            height: 50,
            cornerRadius: 12
        )
        let renderSize = CGSize(width: 1_000, height: 1_000)
        let rasterScale = GeneratedRasterPolicy.generatedLayerRasterScale(
            transformScale: CGSize(width: 1, height: 1),
            qualityScale: 1,
            logicalSize: CGSize(width: 100, height: 50),
            renderSize: renderSize
        )
        let layout = ShapeRasterLayout(
            shape: shape,
            at: 0,
            logicalRenderScale: 1,
            rasterScale: rasterScale
        )
        let image = try MetalFrameRenderer().renderShapeLayer(
            shape,
            at: 0,
            logicalRenderScale: 1,
            rasterScale: rasterScale
        )

        #expect(image.extent.integral.size == layout.rasterSize)
        #expect(layout.rasterSize == CGSize(width: 1_000, height: 1_000))
        #expect(layout.rasterCornerRadius == 120)
    }

    @MainActor
    @Test func nonUniformScaledGeneratedShapeRendersFromAxisMatchedRaster() throws {
        let shape = ClipShape(
            kind: .rectangle,
            color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
            width: 600,
            height: 2
        )
        var transform = ClipTransform()
        transform.scale = AnimatableScale(
            baseValue: ScaleValue(x: 1, y: 300),
            isLinked: false
        )
        let descriptor = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: UUID(),
            timelineStart: 0,
            duration: 1,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: transform,
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(),
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: shape,
            text: nil,
            renderOrder: 0
        )
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            600,
            600,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: String]()
            ] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let destination = try #require(pixelBuffer)

        try MetalFrameRenderer().render(
            plan: FrameRenderPlan(
                renderSize: CGSize(width: 600, height: 600),
                renderScale: 1,
                backgroundColor: .black,
                frameDuration: 1 / 30,
                clips: [descriptor],
                quality: .export,
                failurePolicy: .failOnUnavailableEffects
            ),
            compositionTime: .zero,
            sourceFrame: { _ in nil },
            destination: destination,
            isCancelled: { false }
        )

        let center = rgbaPixel(in: destination, x: 300, y: 300)
        let nearTop = rgbaPixel(in: destination, x: 300, y: 5)
        let nearBottom = rgbaPixel(in: destination, x: 300, y: 594)
        #expect(center[0] > 200 && center[1] < 40 && center[2] < 40)
        #expect(nearTop[0] > 180)
        #expect(nearBottom[0] > 180)
    }

    @MainActor
    @Test func generatedCanvasLayersUseProxyFrameWithFullVectorRasterScale() async throws {
        let text = TextTimelineItem(
            text: "Full resolution",
            timelineStart: 0,
            duration: 1
        )
        let project = EditorProject(
            title: "Vector preview",
            renderSettings: RenderSettings(width: 1080, height: 1920, frameRate: 30),
            tracks: [
                TimelineTrack(
                    name: "Text",
                    kind: .text,
                    items: [.text(text)]
                )
            ]
        )

        let prepared = try await CompositionRenderService().preparePreview(
            for: project,
            quality: .balanced,
            invalidation: [.previewFrame, .compositionTopology, .audioMix]
        )

        let videoComposition = try #require(prepared?.videoComposition)
        let instruction = try #require(
            videoComposition.instructions.first
                as? MotionaryVideoCompositionInstruction
        )
        #expect(videoComposition.renderSize == CGSize(width: 540, height: 960))
        #expect(instruction.renderScale == 0.5)
        #expect(instruction.vectorRenderScale == 0.75)
    }

    @Test func generatedTextIsActiveInItsFirstOverlappingFrame() {
        let text = TextTimelineItem(
            text: "Frame aligned",
            timelineStart: 1.01,
            duration: 1
        )
        let descriptor = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: text.id,
            timelineStart: text.timelineStart,
            duration: text.duration,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: text.visuals.transform,
            adjustments: text.visuals.adjustments,
            effectStack: text.visuals.effectStack,
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: nil,
            text: text,
            renderOrder: 0
        )
        let instruction = MotionaryVideoCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600)),
            clips: [descriptor],
            sourceTrackIDs: [],
            renderSize: CGSize(width: 1080, height: 1920),
            renderScale: 1,
            backgroundColor: .black,
            frameDuration: 1 / 30
        )

        #expect(instruction.activeClips(at: 0.97).isEmpty)
        #expect(instruction.activeClips(at: 1).map(\.clipID) == [text.id])
    }

    @Test func renderPlanCarriesIntervalsAndLivePreviewOverrides() {
        let text = TextTimelineItem(
            text: "Live",
            timelineStart: 0,
            duration: 2
        )
        let descriptor = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: text.id,
            timelineStart: text.timelineStart,
            duration: text.duration,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: text.visuals.transform,
            adjustments: text.visuals.adjustments,
            effectStack: text.visuals.effectStack,
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: nil,
            text: text,
            renderOrder: 0
        )
        let liveState = LivePreviewRenderState()
        var liveTransform = text.visuals.transform
        liveTransform.positionX = AnimatableProperty(baseValue: 0.42)
        liveState.setTransform(liveTransform, for: text.id)
        liveState.setInteractiveQualityOverride(true)
        let instruction = MotionaryVideoCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)),
            clips: [descriptor],
            sourceTrackIDs: [],
            renderSize: CGSize(width: 1080, height: 1920),
            renderScale: 0.5,
            vectorRenderScale: 1,
            backgroundColor: .black,
            frameDuration: 1 / 30,
            livePreviewState: liveState
        )

        let plan = RenderPlanCompiler.compile(instruction)
        let resolved = descriptor.resolvingLiveOverride(from: plan.livePreviewSnapshot)

        #expect(plan.clipIntervals.count == instruction.clipIntervals.count)
        #expect(plan.renderScale == 0.5)
        #expect(plan.vectorRenderScale == 1)
        #expect(plan.viewport.visibleRect == CGRect(x: 0, y: 0, width: 1080, height: 1920))
        #expect(plan.viewport.overscanRect.contains(plan.viewport.visibleRect))
        #expect(plan.livePreviewState === liveState)
        #expect(plan.livePreviewSnapshot != nil)
        #expect(plan.quality == .interactive)
        #expect(resolved.transform.positionX.baseValue == 0.42)
        #expect(descriptor.transform.positionX.baseValue == 0)

        var newerTransform = liveTransform
        newerTransform.positionX = AnimatableProperty(baseValue: 0.75)
        liveState.setTransform(newerTransform, for: text.id)
        let frameStable = descriptor.resolvingLiveOverride(from: plan.livePreviewSnapshot)
        #expect(frameStable.transform.positionX.baseValue == 0.42)

        liveState.setHidden(true, for: text.id)
        liveState.revealPreservingTransform(for: text.id)

        #expect(liveState.isHidden(text.id) == false)
        #expect(liveState.transform(for: text.id)?.positionX.baseValue == 0.75)
    }

    @MainActor
    @Test func liveVisualOverrideRendersFullInspectorStateWithoutDescriptorRebuild() throws {
        let descriptor = shapeDescriptor(
            transform: ClipTransform(),
            color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
            width: 100,
            height: 100,
            renderOrder: 0
        )
        var noir = try #require(
            EffectRegistry.shared.makeEffect(moduleID: .noir)
        )
        noir.mix = AnimatableProperty(baseValue: 1)
        var inspectorTransform = descriptor.transform
        inspectorTransform.positionX = AnimatableProperty(baseValue: 0.35)
        inspectorTransform.scale.baseValue = ScaleValue(x: 1.25, y: 1.25)
        let inspectorMask = ItemMask(
            shape: .ellipse,
            widthScale: 0.8,
            heightScale: 0.8
        )
        let inspectorVisuals = TimelineItemVisuals(
            transform: inspectorTransform,
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(effects: [noir]),
            blendMode: .normal,
            blendIntensity: 0.85,
            mask: inspectorMask
        )
        var inspectorShape = try #require(descriptor.shape)
        inspectorShape.width = AnimatableProperty(baseValue: 96)

        // A direct canvas transform intentionally wins over the transform
        // carried by the inspector's full visual state.
        var canvasTransform = descriptor.transform
        canvasTransform.positionX = AnimatableProperty(baseValue: 0)
        let liveState = LivePreviewRenderState()
        liveState.setTransform(canvasTransform, for: descriptor.clipID)
        liveState.setVisuals(
            inspectorVisuals,
            shape: inspectorShape,
            for: descriptor.clipID
        )

        let snapshot = liveState.snapshot()
        let resolved = descriptor.resolvingLiveOverride(from: snapshot)
        #expect(resolved.transform.positionX.baseValue == 0)
        #expect(resolved.effectStack.effects.count == 1)
        #expect(resolved.effectStack.effects[0].moduleID == .noir)
        #expect(resolved.effectStack.effects[0].isEnabled)
        #expect(resolved.mask == inspectorMask)
        #expect(resolved.blendIntensity == 0.85)
        #expect(resolved.shape == inspectorShape)
        #expect(resolved.hasTransientRasterScaleOverride == false)

        // The live effect stack is consumed by the actual frame renderer. A
        // fully red source becomes achromatic while the immutable descriptor
        // itself remains unchanged.
        let pixel = try renderPixel(
            clips: [descriptor],
            x: 50,
            y: 50,
            livePreviewState: liveState
        )
        #expect(abs(Int(pixel[0]) - Int(pixel[1])) < 18)
        #expect(abs(Int(pixel[1]) - Int(pixel[2])) < 18)
        #expect(descriptor.effectStack.effects.isEmpty)
        #expect(descriptor.shape?.width.baseValue == 100)
    }

    @Test func liveTextOverrideAndGranularCommitHandoffPreserveCanvasState() {
        let text = TextTimelineItem(
            text: "Before",
            timelineStart: 0,
            duration: 2
        )
        let descriptor = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: text.id,
            timelineStart: text.timelineStart,
            duration: text.duration,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: text.visuals.transform,
            adjustments: text.visuals.adjustments,
            effectStack: text.visuals.effectStack,
            mask: text.visuals.mask,
            backgroundRemoval: text.visuals.backgroundRemoval,
            blendMode: text.visuals.blendMode,
            blendIntensity: text.visuals.blendIntensity,
            shape: nil,
            text: text,
            renderOrder: 0
        )
        var editedText = text
        editedText.text = "After"
        editedText.style.fontSize = 72
        var editedVisuals = editedText.visuals
        editedVisuals.blendMode = .screen
        editedText.visuals = editedVisuals
        var canvasTransform = text.visuals.transform
        canvasTransform.rotationDegrees = AnimatableProperty(baseValue: 12)

        let liveState = LivePreviewRenderState()
        liveState.setTransform(canvasTransform, for: text.id)
        liveState.setHidden(true, for: text.id)
        liveState.setVisuals(editedVisuals, text: editedText, for: text.id)

        let resolved = descriptor.resolvingLiveOverride(from: liveState.snapshot())
        #expect(resolved.text?.text == "After")
        #expect(resolved.text?.style.fontSize == 72)
        #expect(resolved.blendMode == .screen)
        #expect(resolved.transform.rotationDegrees.baseValue == 12)
        #expect(resolved.transform.opacity.baseValue == 0)

        let revisionBeforeClear = liveState.snapshot().revision
        let revisionAfterClear = liveState.clearVisuals(for: text.id)
        let canvasHandoff = liveState.override(for: text.id)
        #expect(revisionAfterClear > revisionBeforeClear)
        #expect(canvasHandoff?.visuals == nil)
        #expect(canvasHandoff?.text == nil)
        #expect(canvasHandoff?.transform == canvasTransform)
        #expect(canvasHandoff?.isHidden == true)

        liveState.clearOverride(for: text.id)
        #expect(liveState.override(for: text.id) == nil)
        #expect(!liveState.hasActiveOverrides)
    }

    @Test func effectDiagnosticsDeduplicateFramesAndReemitAfterInterval() {
        let clock = DiagnosticsTestClock()
        let diagnostics = EffectRenderDiagnostics(
            repeatInterval: 1,
            maximumRetainedSignatures: 2,
            clock: { clock.now }
        )
        let recorder = DiagnosticsRecorder()
        let handler = diagnostics.installHandler { recorder.append($0) }
        defer { diagnostics.removeHandler(handler) }
        let effectID = UUID()
        let repeated = EffectRenderDiagnostic(
            severity: .warning,
            moduleID: "missing.preview.effect",
            effectID: effectID,
            message: "Unavailable on this device"
        )

        diagnostics.report(repeated)
        diagnostics.report(repeated)
        clock.advance(by: 0.75)
        diagnostics.report(repeated)
        #expect(recorder.count == 1)

        clock.advance(by: 0.26)
        diagnostics.report(repeated)
        #expect(recorder.count == 2)

        for index in 0..<4 {
            diagnostics.report(
                EffectRenderDiagnostic(
                    severity: .warning,
                    moduleID: "missing.preview.effect.\(index)",
                    effectID: UUID(),
                    message: "Unavailable \(index)"
                )
            )
        }
        #expect(recorder.count == 6)
        #expect(diagnostics.retainedSignatureCount <= 2)
    }

    @Test func standaloneEffectDiagnosticsUseStableEffectIdentity() {
        let effect = EffectInstance(
            id: UUID(),
            moduleID: .noir,
            seed: 0
        )
        #expect(
            EffectImageRenderer.diagnosticEffectID(
                for: EffectStack(effects: [effect])
            ) == effect.id
        )
        let firstFallback = EffectImageRenderer.diagnosticEffectID(for: EffectStack())
        let secondFallback = EffectImageRenderer.diagnosticEffectID(for: EffectStack())
        #expect(firstFallback == secondFallback)
    }

    @Test func overlayEffectsPreserveTransparentSourceRegions() throws {
        let size = CGSize(width: 64, height: 64)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let source = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        }
        let input = CIImage(cgImage: try #require(source.cgImage))
        let transparentHalf = CGRect(x: 32, y: 0, width: 32, height: 64)

        for moduleID in [
            EffectModuleID.lightLeak,
            .fineGrain,
            .analogGlitch,
        ] {
            var effect = try #require(
                EffectRegistry.shared.makeEffect(moduleID: moduleID)
            )
            effect.mix = AnimatableProperty(baseValue: 1)
            let output = EffectImageRenderer.render(
                EffectStack(effects: [effect]),
                to: input,
                at: 0,
                renderScale: 1
            )

            #expect(averageAlpha(in: transparentHalf, of: output) < 1)
        }
    }

    @MainActor
    @Test(arguments: BackgroundRemovalMode.allCases)
    func backgroundCutoutSurvivesCompositionAndEncodedExport(mode: BackgroundRemovalMode) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
            UIColor.red.setFill()
            context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        }
        let url = directory.appendingPathComponent("source.png")
        try #require(image.pngData()).write(to: url)
        let source = ClipSource(url: url, mediaType: .image, originalDuration: 0.4,
            naturalSize: CGSizeValue(width: 64, height: 64))
        let clip = TimelineClip(name: "Cutout", source: source, timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 0.4))
        var project = EditorProject(title: "Cutout", renderSettings: RenderSettings(width: 64, height: 64, frameRate: 10),
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])])
        let uncutProject = project
        var item = try #require(project.item(id: clip.id))
        var visuals = try #require(item.editableVisuals)
        visuals.backgroundRemoval = BackgroundRemovalSettings(mode: mode, strokes: [
            BackgroundBrushStroke(points: [BackgroundBrushPoint(x: 0.25, y: 0.5)], diameter: 0.4, restores: false)
        ])
        item.editableVisuals = visuals
        project.replaceItem(id: clip.id, with: item)
        if mode == .automatic {
            let mask = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
                UIColor.black.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                UIColor.white.setFill()
                context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
            }
            let maskURL = directory.appendingPathComponent("matte.png")
            try #require(mask.pngData()).write(to: maskURL)
            let mediaID = try #require(project.mediaLibrary.keys.first)
            project.mediaLibrary[mediaID]?.backgroundRemovalArtifact = BackgroundRemovalArtifact(
                url: maskURL, sourceRange: clip.sourceRange, sourceFingerprint: "fixture")
        }
        let settings = VideoExportSettings(width: 64, height: 64, frameRate: 10,
            videoBitrate: 500_000, audioBitrate: 96_000, codec: .h264, container: .mp4)
        let output = try await VideoExportService().export(project: project, settings: settings, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: output) }
        let frame = try await AVAssetImageGenerator(asset: AVURLAsset(url: output))
            .image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        let removed = try rgbaPixel(in: frame, x: 16, y: 32)
        let retained = try rgbaPixel(in: frame, x: 48, y: 32)
        #expect(removed[0] < 25 && removed[1] < 25 && removed[2] < 25)
        #expect(retained[0] > 180 && retained[1] < 40 && retained[2] < 40)
        if mode != .automatic {
            let rawVideo = try await VideoExportService().export(project: uncutProject, settings: settings, progress: { _ in })
            defer { try? FileManager.default.removeItem(at: rawVideo) }
            let mediaID = try #require(project.mediaLibrary.keys.first)
            project.mediaLibrary[mediaID]?.url = rawVideo
            project.mediaLibrary[mediaID]?.mediaType = .video
            if case .media(var media) = project.item(id: clip.id) {
                media.mediaType = .video
                project.replaceItem(id: media.id, with: .media(media))
            }
            let videoOutput = try await VideoExportService().export(project: project, settings: settings, progress: { _ in })
            defer { try? FileManager.default.removeItem(at: videoOutput) }
            let videoFrame = try await AVAssetImageGenerator(asset: AVURLAsset(url: videoOutput))
                .image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
            let keyed = try rgbaPixel(in: videoFrame, x: 16, y: 32)
            let subject = try rgbaPixel(in: videoFrame, x: 48, y: 32)
            #expect(keyed[0] < 25 && keyed[1] < 25 && keyed[2] < 25)
            #expect(subject[0] > 180 && subject[1] < 40 && subject[2] < 40)
        }
    }

    @MainActor
    @Test func configurableExporterWritesRequestedDimensions() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 96)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 96))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 32, y: 0, width: 32, height: 96))
        }
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-export-source.png")
        try #require(image.pngData()).write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let source = ClipSource(
            url: sourceURL,
            mediaType: .image,
            originalDuration: 0.2,
            naturalSize: CGSizeValue(width: 64, height: 96)
        )
        let clip = TimelineClip(
            name: "Export",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 0.2)
        )
        var project = EditorProject(
            title: "Export",
            renderSettings: RenderSettings(width: 64, height: 96, frameRate: 10),
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        project.setSpeedMap(
            for: clip.id,
            speedMap: .constant(speed: 0.5)
        )
        let settings = VideoExportSettings(
            width: 80,
            height: 120,
            frameRate: 10,
            videoBitrate: 500_000,
            audioBitrate: 96_000,
            codec: .h264,
            container: .mp4
        )

        let outputURL = try await VideoExportService().export(
            project: project,
            settings: settings,
            progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let outputAsset = AVURLAsset(url: outputURL)
        let outputTrack = try #require(
            try await outputAsset.loadTracks(withMediaType: .video).first
        )
        let outputSize = try await outputTrack.load(.naturalSize)

        #expect(Int(outputSize.width.rounded()) == 80)
        #expect(Int(outputSize.height.rounded()) == 120)
        #expect(CMTimeGetSeconds(try await outputAsset.load(.duration)) > 0.28)

        let frame = try await AVAssetImageGenerator(asset: outputAsset).image(
            at: CMTime(seconds: 0.24, preferredTimescale: 600)
        ).image
        let pixel = try averageRGBA(in: frame)
        #expect(pixel[0] > 10 || pixel[1] > 10 || pixel[2] > 10)
    }

    @MainActor
    @Test func stillImageExportPreservesTopToBottomOrientation() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
        }
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-export-orientation-source.png")
        try #require(image.pngData()).write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let source = ClipSource(
            url: sourceURL,
            mediaType: .image,
            originalDuration: 0.4,
            naturalSize: CGSizeValue(width: 64, height: 64)
        )
        let clip = TimelineClip(
            name: "Export Orientation",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 0.4)
        )
        let project = EditorProject(
            title: "Export Orientation",
            renderSettings: RenderSettings(width: 64, height: 64, frameRate: 10),
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        let settings = VideoExportSettings(
            width: 64,
            height: 64,
            frameRate: 10,
            videoBitrate: 500_000,
            audioBitrate: 96_000,
            codec: .h264,
            container: .mp4
        )

        let outputURL = try await VideoExportService().export(
            project: project,
            settings: settings,
            progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let outputAsset = AVURLAsset(url: outputURL)
        let frame = try await AVAssetImageGenerator(asset: outputAsset).image(
            at: CMTime(seconds: 0.2, preferredTimescale: 600)
        ).image
        let top = try rgbaPixel(in: frame, x: 32, y: 8)
        let bottom = try rgbaPixel(in: frame, x: 32, y: 56)
        #expect(top[0] > top[2])
        #expect(bottom[2] > bottom[0])
    }

    @MainActor
    @Test func stillImageDescriptorRendersPixelsWithoutSourceTrack() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 96)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 96))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 32, y: 0, width: 32, height: 96))
        }
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-still-source.png")
        try #require(image.pngData()).write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let descriptor = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            stillImageURL: sourceURL,
            clipID: UUID(),
            timelineStart: 0,
            duration: 0.4,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(),
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(),
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: nil,
            text: nil,
            renderOrder: 0
        )
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            80,
            120,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: String]()
            ] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let destination = try #require(pixelBuffer)

        try MetalFrameRenderer().render(
            plan: FrameRenderPlan(
                renderSize: CGSize(width: 80, height: 120),
                renderScale: 1,
                backgroundColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1),
                frameDuration: 0.1,
                clips: [descriptor],
                quality: .export,
                failurePolicy: .failOnUnavailableEffects
            ),
            compositionTime: CMTime(seconds: 0.24, preferredTimescale: 600),
            sourceFrame: { _ in nil },
            destination: destination,
            isCancelled: { false }
        )

        let pixel = averageRGBA(in: destination)
        #expect(pixel[0] > 10 || pixel[1] > 10 || pixel[2] > 10)
    }

    @MainActor
    @Test func stillImageRenderPreservesTopToBottomOrientation() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
        }
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-oriented-still.png")
        try #require(image.pngData()).write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let descriptor = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            stillImageURL: sourceURL,
            clipID: UUID(),
            timelineStart: 0,
            duration: 0.4,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(),
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(),
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: nil,
            text: nil,
            renderOrder: 0
        )
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: String]()
            ] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let destination = try #require(pixelBuffer)

        try MetalFrameRenderer().render(
            plan: FrameRenderPlan(
                renderSize: CGSize(width: 64, height: 64),
                renderScale: 1,
                backgroundColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1),
                frameDuration: 0.1,
                clips: [descriptor],
                quality: .export,
                failurePolicy: .failOnUnavailableEffects
            ),
            compositionTime: CMTime(seconds: 0, preferredTimescale: 600),
            sourceFrame: { _ in nil },
            destination: destination,
            isCancelled: { false }
        )

        let top = rgbaPixel(in: destination, x: 32, y: 8)
        let bottom = rgbaPixel(in: destination, x: 32, y: 56)
        #expect(top[0] > top[2])
        #expect(bottom[2] > bottom[0])
    }

    @MainActor
    @Test func stillImageCacheUsesPreparedIdentityWithoutFramePathFileIO() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-mutable-still.png")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try writeSolidImage(.systemRed, to: sourceURL, modificationOffset: 10)
        let renderer = try MetalFrameRenderer()
        let first = try renderStillAverage(
            url: sourceURL,
            cacheIdentity: "still-v1",
            renderer: renderer
        )
        try FileManager.default.removeItem(at: sourceURL)
        let cachedAfterRemoval = try renderStillAverage(
            url: sourceURL,
            cacheIdentity: "still-v1",
            renderer: renderer
        )
        try writeSolidImage(.systemBlue, to: sourceURL, modificationOffset: 20)
        let second = try renderStillAverage(
            url: sourceURL,
            cacheIdentity: "still-v2",
            renderer: renderer
        )

        #expect(first[0] > first[2])
        #expect(cachedAfterRemoval[0] > cachedAfterRemoval[2])
        #expect(second[2] > second[0])
    }

    @MainActor
    @Test func renderTransformPositiveYMovesLayerTowardTopOfCanvas() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-position-y.png")
        try #require(image.pngData()).write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let transform = ClipTransform(
            positionX: AnimatableProperty(baseValue: 0),
            positionY: AnimatableProperty(baseValue: 0.75),
            scale: AnimatableScale(baseValue: ScaleValue(x: 0.35, y: 0.35)),
            rotationDegrees: AnimatableProperty(baseValue: 0),
            opacity: AnimatableProperty(baseValue: 1)
        )
        let descriptor = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            stillImageURL: sourceURL,
            clipID: UUID(),
            timelineStart: 0,
            duration: 0.4,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: transform,
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(),
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: nil,
            text: nil,
            renderOrder: 0
        )
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            100,
            100,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: String]()
            ] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let destination = try #require(pixelBuffer)

        try MetalFrameRenderer().render(
            plan: FrameRenderPlan(
                renderSize: CGSize(width: 100, height: 100),
                renderScale: 1,
                backgroundColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1),
                frameDuration: 0.1,
                clips: [descriptor],
                quality: .export,
                failurePolicy: .failOnUnavailableEffects
            ),
            compositionTime: CMTime(seconds: 0, preferredTimescale: 600),
            sourceFrame: { _ in nil },
            destination: destination,
            isCancelled: { false }
        )

        let top = rgbaPixel(in: destination, x: 50, y: 14)
        let bottom = rgbaPixel(in: destination, x: 50, y: 86)
        #expect(top[0] > 80)
        #expect(bottom[0] < 20)
    }

    @MainActor
    @Test func shapeRenderOrderDoesNotAffectPosition() throws {
        let transform = ClipTransform(
            positionX: AnimatableProperty(baseValue: 0.45),
            positionY: AnimatableProperty(baseValue: 0.2),
            scale: AnimatableScale(baseValue: ScaleValue(x: 1, y: 1)),
            rotationDegrees: AnimatableProperty(baseValue: 0),
            opacity: AnimatableProperty(baseValue: 1)
        )
        let red = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: UUID(),
            timelineStart: 0,
            duration: 1,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: transform,
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(),
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: ClipShape(
                kind: .rectangle,
                color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
                width: 20,
                height: 20
            ),
            text: nil,
            renderOrder: 0
        )
        var greenTransform = ClipTransform()
        greenTransform.positionX = AnimatableProperty(baseValue: -0.5)
        let green = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: UUID(),
            timelineStart: 0,
            duration: 1,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: greenTransform,
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(),
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: ClipShape(
                kind: .rectangle,
                color: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1),
                width: 20,
                height: 20
            ),
            text: nil,
            renderOrder: 1
        )

        let first = try renderShapeOrderPixel(clips: [red, green])
        let redAbove = shapeDescriptor(
            transform: transform,
            color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
            renderOrder: 1
        )
        let greenBelow = shapeDescriptor(
            transform: greenTransform,
            color: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1),
            renderOrder: 0
        )
        let second = try renderShapeOrderPixel(clips: [redAbove, greenBelow])

        #expect(first[0] > 120)
        #expect(second[0] > 120)
        #expect(abs(Int(first[0]) - Int(second[0])) < 8)
    }

    @MainActor
    @Test func triangleMaskPreservesTopToBottomOrientation() throws {
        let descriptor = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: UUID(),
            timelineStart: 0,
            duration: 0.4,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(),
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(),
            mask: ItemMask(
                shape: .triangle,
                widthScale: 0.8,
                heightScale: 0.8,
                roundnessScale: 0
            ),
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: ClipShape(
                kind: .rectangle,
                color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
                width: 100,
                height: 100
            ),
            text: nil,
            renderOrder: 0
        )
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            100,
            100,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: String]()
            ] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let destination = try #require(pixelBuffer)

        try MetalFrameRenderer().render(
            plan: FrameRenderPlan(
                renderSize: CGSize(width: 100, height: 100),
                renderScale: 1,
                backgroundColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1),
                frameDuration: 0.1,
                clips: [descriptor],
                quality: .export,
                failurePolicy: .failOnUnavailableEffects
            ),
            compositionTime: CMTime(seconds: 0, preferredTimescale: 600),
            sourceFrame: { _ in nil },
            destination: destination,
            isCancelled: { false }
        )

        let upperLeft = rgbaPixel(in: destination, x: 20, y: 25)
        let lowerLeft = rgbaPixel(in: destination, x: 20, y: 75)
        #expect(upperLeft[0] < 20)
        #expect(lowerLeft[0] > 80)
    }

    @Test func adjustmentCompositionUsesDedicatedRenderRoleAndStackOrder() async throws {
        let shape = ShapeTimelineItem(
            name: "Background",
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
        let adjustment = AdjustmentTimelineItem(
            timelineStart: 0,
            duration: 1
        )
        let project = EditorProject(
            title: "Typed adjustment render",
            renderSettings: RenderSettings(width: 64, height: 64, frameRate: 10),
            tracks: [
                TimelineTrack(
                    name: "Adjustment",
                    kind: .visual,
                    items: [.adjustment(adjustment)]
                ),
                TimelineTrack(
                    name: "Shape",
                    kind: .shape,
                    items: [.shape(shape)]
                ),
            ]
        )

        let rendered = try await CompositionRenderService().makeComposition(for: project)
        let instruction = try #require(
            rendered.videoComposition?.instructions.first
                as? MotionaryVideoCompositionInstruction
        )

        #expect(instruction.clips.map(\.role) == [.content, .adjustment])
        #expect(instruction.clips.map(\.clipID) == [shape.id, adjustment.id])
        #expect(instruction.clips.last?.trackID == kCMPersistentTrackID_Invalid)
        #expect(instruction.clips.last?.shape == nil)
        #expect(instruction.clips.last?.text == nil)
    }

    @Test func exportValidationIncludesAdjustmentEffectStacks() throws {
        let unsupportedEffect = EffectInstance(
            moduleID: "com.example.motionary.unsupported-adjustment"
        )
        let adjustment = AdjustmentTimelineItem(
            timelineStart: 0,
            duration: 1,
            visuals: TimelineItemVisuals(
                effectStack: EffectStack(effects: [unsupportedEffect])
            )
        )
        let project = EditorProject(
            title: "Adjustment effect validation",
            tracks: [
                TimelineTrack(
                    name: "Adjustment",
                    kind: .visual,
                    items: [.adjustment(adjustment)]
                )
            ]
        )

        do {
            try VideoExportService().validateRenderingAvailability(for: project)
            Issue.record("Unsupported adjustment effect passed export validation")
        } catch MetalRenderingError.unavailableEffect(let name) {
            #expect(name.contains("unsupported-adjustment"))
        } catch {
            Issue.record("Unexpected export validation error: \(error)")
        }
    }

    @MainActor
    @Test func adjustmentTargetsRespectLayerOrderAndExclusions() throws {
        let redID = UUID()
        let greenID = UUID()
        var red = shapeDescriptor(transform: ClipTransform(),
            color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
            width: 100, height: 100, renderOrder: 0)
        red.layerID = redID
        var green = shapeDescriptor(transform: ClipTransform(),
            color: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1),
            width: 20, height: 20, renderOrder: 1)
        green.layerID = greenID
        var adjustment = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid, backgroundMaskTrackID: nil,
            clipID: UUID(), timelineStart: 0, duration: 1,
            sourceTransform: .identity, backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(),
            adjustments: AdjustmentSettings(saturation: AnimatableProperty(baseValue: 0)),
            effectStack: EffectStack(), mask: nil, backgroundRemoval: nil,
            blendMode: .normal, blendIntensity: 1, shape: nil, text: nil,
            role: .adjustment, renderOrder: 2)
        for targets in [
            AdjustmentLayerTargets(mode: .selected, trackIDs: [redID]),
            AdjustmentLayerTargets(mode: .excluding, trackIDs: [greenID])
        ] {
            adjustment.adjustmentTargets = targets
            let affected = try renderPixel(clips: [red, green, adjustment], x: 10, y: 10)
            let excluded = try renderPixel(clips: [red, green, adjustment], x: 50, y: 50)
            #expect(abs(Int(affected[0]) - Int(affected[1])) < 12)
            #expect(excluded[1] > excluded[0] + 60)
        }

        adjustment.adjustmentTargets = AdjustmentLayerTargets(mode: .selected, trackIDs: [])
        let unaffected = try renderPixel(clips: [red, green, adjustment], x: 10, y: 10)
        #expect(unaffected[0] > unaffected[1] + 60)
    }

    @MainActor
    @Test(arguments: [2, 64])
    func selectiveAdjustmentRendersEffectOnceForCombinedCanvas(includedCount: Int) throws {
        let recorder = AdjustmentExtentRecorder()
        let renderer = try MetalFrameRenderer(effectRegistry: EffectRenderRegistry(modules: [recorder]))
        var inputs: [RenderClipDescriptor] = []
        for index in 0..<includedCount {
            var input = shapeDescriptor(transform: ClipTransform(), color: .white, renderOrder: index)
            input.layerID = UUID()
            inputs.append(input)
        }
        let excluded = UUID()
        var third = shapeDescriptor(transform: ClipTransform(), color: .white, renderOrder: includedCount)
        third.layerID = excluded
        let effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .sepia))
        var adjustment = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid, backgroundMaskTrackID: nil,
            clipID: UUID(), timelineStart: 0, duration: 1,
            sourceTransform: .identity, backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(), adjustments: AdjustmentSettings(),
            effectStack: EffectStack(effects: [effect]), mask: nil, backgroundRemoval: nil,
            blendMode: .normal, blendIntensity: 1, shape: nil, text: nil,
            role: .adjustment, renderOrder: includedCount + 1
        )
        adjustment.adjustmentTargets = AdjustmentLayerTargets(mode: .excluding, trackIDs: [excluded])
        _ = try renderPixel(clips: inputs + [third, adjustment], x: 50, y: 50, renderer: renderer)
        #expect(recorder.extents == [CGRect(x: 0, y: 0, width: 100, height: 100)])
    }

    @MainActor
    @Test func nestedSelectiveGroupsStayAtomicAndRenderOncePerAdjustment() throws {
        let recorder = AdjustmentExtentRecorder()
        let renderer = try MetalFrameRenderer(effectRegistry: EffectRenderRegistry(modules: [recorder]))
        var a = shapeDescriptor(transform: ClipTransform(), color: .white, renderOrder: 0)
        a.layerID = UUID()
        var b = shapeDescriptor(transform: ClipTransform(), color: .white, renderOrder: 1)
        b.layerID = UUID()
        var excluded = shapeDescriptor(transform: ClipTransform(), color: .white, renderOrder: 2)
        excluded.layerID = UUID()
        let aID = try #require(a.layerID)
        let bID = try #require(b.layerID)
        let excludedID = try #require(excluded.layerID)
        let effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .sepia))
        func adjustment(order: Int, targets: AdjustmentLayerTargets, transform: ClipTransform = ClipTransform()) -> RenderClipDescriptor {
            var descriptor = RenderClipDescriptor(
                trackID: kCMPersistentTrackID_Invalid, backgroundMaskTrackID: nil,
                clipID: UUID(), timelineStart: 0, duration: 1,
                sourceTransform: .identity, backgroundMaskSourceTransform: .identity,
                transform: transform, adjustments: AdjustmentSettings(),
                effectStack: EffectStack(effects: [effect]), mask: nil, backgroundRemoval: nil,
                blendMode: .normal, blendIntensity: 1, shape: nil, text: nil,
                role: .adjustment, renderOrder: order)
            descriptor.layerID = UUID()
            descriptor.adjustmentTargets = targets
            return descriptor
        }
        let lower = adjustment(order: 3, targets: AdjustmentLayerTargets(mode: .selected, trackIDs: [aID, bID]))
        let upper = adjustment(order: 4, targets: AdjustmentLayerTargets(mode: .selected, trackIDs: [aID]),
            transform: ClipTransform(positionX: AnimatableProperty(baseValue: 0.3)))
        let clips = [a, b, excluded, lower, upper]
        _ = try renderPixel(clips: clips, x: 50, y: 50, renderer: renderer)
        #expect(recorder.extents == Array(repeating: CGRect(x: 0, y: 0, width: 100, height: 100), count: 2))
        let placements = AdjustmentScenePlacement(clips: clips, canvasSize: CGSize(width: 100, height: 100)).transforms(at: 0)
        #expect(abs(placements[0].tx - 15) < 0.001)
        #expect(placements[0] == placements[1])
        #expect(placements[2] == .identity)
        let excludingUpper = adjustment(order: 4, targets: AdjustmentLayerTargets(mode: .excluding, trackIDs: [excludedID, aID]))
        _ = try renderPixel(clips: [a, b, excluded, lower, excludingUpper], x: 50, y: 50, renderer: renderer)
        // Lower group renders once. Upper excludes that whole group plus the
        // remaining source, so it has no input and issues no effect pass.
        #expect(recorder.extents.count == 3)
    }

    @MainActor
    @Test(arguments: [EffectModuleID.blur, .vignette, .pixelate, .barrelWarp])
    func selectiveGroupMatchesCanvasComposite(moduleID: EffectModuleID) throws {
        let excludedID = UUID()
        var left = shapeDescriptor(transform: ClipTransform(positionX: AnimatableProperty(baseValue: -0.35)),
            color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1), width: 24, height: 35, renderOrder: 0)
        left.layerID = UUID()
        var right = shapeDescriptor(transform: ClipTransform(positionX: AnimatableProperty(baseValue: 0.3)),
            color: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1), width: 30, height: 20, renderOrder: 1)
        right.layerID = UUID()
        var excluded = shapeDescriptor(transform: ClipTransform(opacity: AnimatableProperty(baseValue: 0)),
            color: .white, renderOrder: 2)
        excluded.layerID = excludedID
        let effect = try #require(EffectRegistry.shared.makeEffect(moduleID: moduleID))
        var adjustment = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid, backgroundMaskTrackID: nil,
            clipID: UUID(), timelineStart: 0, duration: 1,
            sourceTransform: .identity, backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(), adjustments: AdjustmentSettings(),
            effectStack: EffectStack(effects: [effect]), mask: nil, backgroundRemoval: nil,
            blendMode: .normal, blendIntensity: 1, shape: nil, text: nil,
            role: .adjustment, renderOrder: 3)
        let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
        let renderer = try MetalFrameRenderer()
        for x in [15, 30, 40, 50, 65, 80] {
            adjustment.adjustmentTargets = AdjustmentLayerTargets()
            let reference = try renderPixel(clips: [left, right, adjustment], x: x, y: 50,
                backgroundColor: clear, renderer: renderer)
            adjustment.adjustmentTargets = AdjustmentLayerTargets(mode: .excluding, trackIDs: [excludedID])
            let scoped = try renderPixel(clips: [left, right, excluded, adjustment], x: x, y: 50,
                backgroundColor: clear, renderer: renderer)
            #expect(zip(reference, scoped).allSatisfy { abs(Int($0) - Int($1)) <= 2 },
                "Scoped \(moduleID.rawValue) differs from the common canvas at x=\(x)")
        }
    }

    @MainActor
    @Test(arguments: [1.0, 0.5, 0.2])
    func selectiveAdjustmentPreservesExcludedMiddleLayerOrder(opacity: Double) throws {
        let recorder = AdjustmentExtentRecorder()
        let renderer = try MetalFrameRenderer(effectRegistry: EffectRenderRegistry(modules: [recorder]))
        let excluded = UUID()
        var bottom = shapeDescriptor(transform: ClipTransform(),
            color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1), width: 100, height: 100, renderOrder: 0)
        bottom.layerID = UUID()
        var middle = shapeDescriptor(transform: ClipTransform(opacity: AnimatableProperty(baseValue: opacity)),
            color: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1), width: 40, height: 40, renderOrder: 1)
        middle.layerID = excluded
        var top = shapeDescriptor(transform: ClipTransform(),
            color: RGBAColor(red: 0, green: 0, blue: 1, alpha: 1), width: 10, height: 10, renderOrder: 2)
        top.layerID = UUID()
        let effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .sepia))
        var adjustment = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid, backgroundMaskTrackID: nil,
            clipID: UUID(), timelineStart: 0, duration: 1,
            sourceTransform: .identity, backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(), adjustments: AdjustmentSettings(),
            effectStack: EffectStack(effects: [effect]), mask: nil, backgroundRemoval: nil,
            blendMode: .normal, blendIntensity: 1, shape: nil, text: nil,
            role: .adjustment, renderOrder: 3
        )
        adjustment.adjustmentTargets = AdjustmentLayerTargets(mode: .excluding, trackIDs: [excluded])
        let clips = [bottom, middle, top, adjustment]
        let middlePixel = try renderPixel(clips: clips, x: 35, y: 50, renderer: renderer)
        let topPixel = try renderPixel(clips: clips, x: 50, y: 50, renderer: renderer)
        let reference = try renderPixel(clips: [bottom, middle, top], x: 35, y: 50, renderer: renderer)
        #expect(zip(middlePixel, reference).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
        #expect(topPixel[2] > topPixel[0] + 60 && topPixel[2] > topPixel[1] + 60)
    }

    @MainActor
    @Test func selectiveColorAdjustmentLeavesMiddleLayerInPlace() throws {
        let excluded = UUID()
        var bottom = shapeDescriptor(transform: ClipTransform(),
            color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1), width: 100, height: 100, renderOrder: 0)
        bottom.layerID = UUID()
        var middle = shapeDescriptor(transform: ClipTransform(),
            color: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1), width: 40, height: 40, renderOrder: 1)
        middle.layerID = excluded
        var top = shapeDescriptor(transform: ClipTransform(),
            color: RGBAColor(red: 0, green: 0, blue: 1, alpha: 1), width: 10, height: 10, renderOrder: 2)
        top.layerID = UUID()
        var adjustment = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid, backgroundMaskTrackID: nil,
            clipID: UUID(), timelineStart: 0, duration: 1,
            sourceTransform: .identity, backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(),
            adjustments: AdjustmentSettings(saturation: AnimatableProperty(baseValue: 0)),
            effectStack: EffectStack(), mask: nil, backgroundRemoval: nil,
            blendMode: .normal, blendIntensity: 1, shape: nil, text: nil,
            role: .adjustment, renderOrder: 3)
        adjustment.adjustmentTargets = AdjustmentLayerTargets(mode: .excluding, trackIDs: [excluded])
        let clips = [bottom, middle, top, adjustment]
        let middlePixel = try renderPixel(clips: clips, x: 35, y: 50)
        let topPixel = try renderPixel(clips: clips, x: 50, y: 50)
        let bottomPixel = try renderPixel(clips: clips, x: 10, y: 10)
        #expect(middlePixel[1] > middlePixel[0] + 60)
        #expect(abs(Int(topPixel[0]) - Int(topPixel[1])) < 12)
        #expect(abs(Int(bottomPixel[0]) - Int(bottomPixel[1])) < 12)
    }

    @MainActor
    @Test func adjustmentLayerOnlyAffectsContentBelowDuringItsTimelineRange() throws {
        let background = shapeDescriptor(
            transform: ClipTransform(),
            color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
            width: 100,
            height: 100,
            renderOrder: 0
        )
        let adjustment = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: UUID(),
            timelineStart: 0.5,
            duration: 1,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(),
            adjustments: AdjustmentSettings(
                saturation: AnimatableProperty(baseValue: 0)
            ),
            effectStack: EffectStack(),
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: nil,
            text: nil,
            role: .adjustment,
            renderOrder: 1
        )
        let foreground = shapeDescriptor(
            transform: ClipTransform(),
            color: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1),
            width: 20,
            height: 20,
            renderOrder: 2
        )
        let clips = [background, adjustment, foreground]

        let beforeRange = try renderPixel(
            clips: clips,
            at: 0.25,
            x: 10,
            y: 10
        )
        let adjustedBelow = try renderPixel(
            clips: clips,
            at: 0.75,
            x: 10,
            y: 10
        )
        let contentAbove = try renderPixel(
            clips: clips,
            at: 0.75,
            x: 50,
            y: 50
        )

        #expect(beforeRange[0] > beforeRange[1] + 60)
        #expect(abs(Int(adjustedBelow[0]) - Int(adjustedBelow[1])) < 12)
        #expect(abs(Int(adjustedBelow[1]) - Int(adjustedBelow[2])) < 12)
        #expect(contentAbove[1] > contentAbove[0] + 60)
        #expect(contentAbove[1] > contentAbove[2] + 60)
    }

    @MainActor
    @Test func typedAdjustmentProjectRendersStackSemanticsEndToEnd() async throws {
        let background = ShapeTimelineItem(
            name: "Background",
            mediaID: MediaID(),
            shape: ClipShape(
                kind: .rectangle,
                color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
                width: 100,
                height: 100
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        let adjustment = AdjustmentTimelineItem(
            timelineStart: 0,
            duration: 1,
            visuals: TimelineItemVisuals(
                adjustments: AdjustmentSettings(
                    saturation: AnimatableProperty(baseValue: 0)
                )
            )
        )
        let foreground = ShapeTimelineItem(
            name: "Foreground",
            mediaID: MediaID(),
            shape: ClipShape(
                kind: .rectangle,
                color: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1),
                width: 20,
                height: 20
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        let project = EditorProject(
            title: "End-to-end adjustment",
            renderSettings: RenderSettings(width: 100, height: 100, frameRate: 30),
            tracks: [
                TimelineTrack(name: "Foreground", kind: .shape, items: [.shape(foreground)]),
                TimelineTrack(name: "Adjustment", kind: .visual, items: [.adjustment(adjustment)]),
                TimelineTrack(name: "Background", kind: .shape, items: [.shape(background)]),
            ]
        )

        let rendered = try await CompositionRenderService().makeComposition(for: project)
        let instruction = try #require(
            rendered.videoComposition?.instructions.first
                as? MotionaryVideoCompositionInstruction
        )
        let adjustedBackground = try renderPixel(
            clips: instruction.clips,
            at: 0.5,
            x: 10,
            y: 10
        )
        let untouchedForeground = try renderPixel(
            clips: instruction.clips,
            at: 0.5,
            x: 50,
            y: 50
        )

        #expect(instruction.qualityProfile == .export)
        #expect(instruction.failurePolicy == .failOnUnavailableEffects)
        #expect(instruction.clips.map(\.clipID) == [background.id, adjustment.id, foreground.id])
        #expect(abs(Int(adjustedBackground[0]) - Int(adjustedBackground[1])) < 12)
        #expect(abs(Int(adjustedBackground[1]) - Int(adjustedBackground[2])) < 12)
        #expect(untouchedForeground[1] > untouchedForeground[0] + 60)
        #expect(untouchedForeground[1] > untouchedForeground[2] + 60)

        var targetedProject = project
        let backgroundTrackID = targetedProject.tracks[2].id
        guard case .adjustment(var targeted) = targetedProject.tracks[1].items[0] else {
            Issue.record("Expected adjustment")
            return
        }
        targeted.targets = AdjustmentLayerTargets(mode: .selected, trackIDs: [backgroundTrackID])
        targetedProject.tracks[1].items[0] = .adjustment(targeted)
        let targetedRender = try await CompositionRenderService().makeComposition(for: targetedProject)
        let targetedInstruction = try #require(
            targetedRender.videoComposition?.instructions.first as? MotionaryVideoCompositionInstruction
        )
        let backgroundDescriptor = try #require(targetedInstruction.clips.first { $0.clipID == background.id })
        let adjustmentDescriptor = try #require(targetedInstruction.clips.first { $0.clipID == targeted.id })
        #expect(backgroundDescriptor.layerID == backgroundTrackID)
        #expect(adjustmentDescriptor.adjustmentTargets == targeted.targets)
        let targetedPixel = try renderPixel(clips: targetedInstruction.clips, at: 0.5, x: 10, y: 10)
        #expect(abs(Int(targetedPixel[0]) - Int(targetedPixel[1])) < 12)
    }

    @MainActor
    @Test(arguments: [0.1, 1.0, 10.0])
    func adjustmentEffectsKeepCanvasExtentWhileZooming(scale: Double) throws {
        let recorder = AdjustmentExtentRecorder()
        let renderer = try MetalFrameRenderer(effectRegistry: EffectRenderRegistry(modules: [recorder]))
        let object = shapeDescriptor(transform: ClipTransform(), color: .white,
                                     width: 100, height: 100, renderOrder: 0)
        var transform = ClipTransform()
        transform.scale = AnimatableScale(baseValue: ScaleValue(x: scale, y: scale))
        let effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .sepia))
        let adjustment = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid, backgroundMaskTrackID: nil,
            clipID: UUID(), timelineStart: 0, duration: 1,
            sourceTransform: .identity, backgroundMaskSourceTransform: .identity,
            transform: transform, adjustments: AdjustmentSettings(), effectStack: EffectStack(effects: [effect]),
            mask: nil, backgroundRemoval: nil, blendMode: .normal, blendIntensity: 1,
            shape: nil, text: nil, role: .adjustment, renderOrder: 1
        )
        _ = try renderPixel(clips: [object, adjustment], x: 50, y: 50, renderer: renderer)
        #expect(recorder.extents == [CGRect(x: 0, y: 0, width: 100, height: 100)])
    }

    @MainActor
    @Test func adjustmentChainsDiscardReplacedSceneBounds() throws {
        let recorder = AdjustmentExtentRecorder()
        let renderer = try MetalFrameRenderer(effectRegistry: EffectRenderRegistry(modules: [recorder]))
        let object = shapeDescriptor(transform: ClipTransform(), color: .white,
                                     width: 100, height: 100, renderOrder: 0)
        func adjustment(scale: Double, order: Int, stack: EffectStack = EffectStack()) -> RenderClipDescriptor {
            var transform = ClipTransform()
            transform.scale = AnimatableScale(baseValue: ScaleValue(x: scale, y: scale))
            return RenderClipDescriptor(
                trackID: kCMPersistentTrackID_Invalid, backgroundMaskTrackID: nil,
                clipID: UUID(), timelineStart: 0, duration: 1,
                sourceTransform: .identity, backgroundMaskSourceTransform: .identity,
                transform: transform, adjustments: AdjustmentSettings(), effectStack: stack,
                mask: nil, backgroundRemoval: nil, blendMode: .normal, blendIntensity: 1,
                shape: nil, text: nil, role: .adjustment, renderOrder: order
            )
        }
        let effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .sepia))
        let pixel = try renderPixel(clips: [object, adjustment(scale: 10, order: 1),
                                           adjustment(scale: 0.1, order: 2),
                                           adjustment(scale: 1, order: 3, stack: EffectStack(effects: [effect]))],
                                    x: 50, y: 50, renderer: renderer)
        #expect(recorder.extents == [CGRect(x: 0, y: 0, width: 100, height: 100)])
        #expect(pixel[0] > 240)
    }

    @MainActor
    @Test func adjustmentTransformLeavesProjectBackgroundInPlace() throws {
        var transform = ClipTransform()
        transform.positionX = AnimatableProperty(baseValue: 1)
        let adjustment = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid, backgroundMaskTrackID: nil,
            clipID: UUID(), timelineStart: 0, duration: 1,
            sourceTransform: .identity, backgroundMaskSourceTransform: .identity,
            transform: transform, adjustments: AdjustmentSettings(), effectStack: EffectStack(),
            mask: nil, backgroundRemoval: nil, blendMode: .normal, blendIntensity: 1,
            shape: nil, text: nil, role: .adjustment, renderOrder: 0
        )
        let pixel = try renderPixel(clips: [adjustment], x: 10, y: 50,
                                    backgroundColor: RGBAColor(red: 0, green: 1, blue: 0, alpha: 1))
        #expect(pixel[1] > 200)
    }

    @MainActor
    @Test func adjustmentTransformRevealsContentOutsideCanvas() throws {
        var objectTransform = ClipTransform()
        objectTransform.positionX = AnimatableProperty(baseValue: 1.5)
        let object = shapeDescriptor(
            transform: objectTransform,
            color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
            renderOrder: 0
        )
        var transform = ClipTransform()
        transform.positionX = AnimatableProperty(baseValue: -1)
        let adjustment = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid, backgroundMaskTrackID: nil,
            clipID: UUID(), timelineStart: 0, duration: 1,
            sourceTransform: .identity, backgroundMaskSourceTransform: .identity,
            transform: transform, adjustments: AdjustmentSettings(), effectStack: EffectStack(),
            mask: nil, backgroundRemoval: nil, blendMode: .normal, blendIntensity: 1,
            shape: nil, text: nil, role: .adjustment, renderOrder: 1
        )
        let pixel = try renderPixel(clips: [object, adjustment], x: 75, y: 50)
        #expect(pixel[0] > 200)
    }

    @MainActor
    @Test func adjustmentTransformMovesUnderlyingComposite() throws {
        let below = shapeDescriptor(
            transform: ClipTransform(),
            color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
            renderOrder: 0
        )
        var transform = ClipTransform()
        transform.positionX = AnimatableProperty(baseValue: 0.5)
        let adjustment = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: UUID(),
            timelineStart: 0,
            duration: 1,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: transform,
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(),
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: nil,
            text: nil,
            role: .adjustment,
            renderOrder: 1
        )
        let original = try renderPixel(clips: [below, adjustment], x: 50, y: 50)
        let moved = try renderPixel(clips: [below, adjustment], x: 75, y: 50)
        #expect(original[0] < 30)
        #expect(moved[0] > 200)
    }

    @MainActor
    @Test func adjustmentLayerEffectAndMaskOperateOnCanvasSizedComposite() throws {
        let background = shapeDescriptor(
            transform: ClipTransform(),
            color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
            width: 100,
            height: 100,
            renderOrder: 0
        )
        var noir = try #require(
            EffectRegistry.shared.makeEffect(moduleID: .noir)
        )
        noir.mix = AnimatableProperty(baseValue: 1)
        let adjustment = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: UUID(),
            timelineStart: 0,
            duration: 1,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(),
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(effects: [noir]),
            mask: ItemMask(
                shape: .ellipse,
                widthScale: 0.5,
                heightScale: 0.5
            ),
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: nil,
            text: nil,
            role: .adjustment,
            renderOrder: 1
        )

        let center = try renderPixel(clips: [background, adjustment], x: 50, y: 50)
        let corner = try renderPixel(clips: [background, adjustment], x: 8, y: 8)

        #expect(abs(Int(center[0]) - Int(center[1])) < 18)
        #expect(abs(Int(center[1]) - Int(center[2])) < 18)
        #expect(corner[0] > corner[1] + 60)
        #expect(corner[0] > corner[2] + 60)
    }

    @MainActor
    @Test func shapeLayerMaskIsAppliedBeforeCompositing() throws {
        let background = shapeDescriptor(
            transform: ClipTransform(),
            color: RGBAColor(red: 0, green: 0, blue: 1, alpha: 1),
            width: 100,
            height: 100,
            renderOrder: 0
        )
        let foreground = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: UUID(),
            timelineStart: 0,
            duration: 1,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(),
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(),
            mask: ItemMask(
                shape: .ellipse,
                widthScale: 0.5,
                heightScale: 0.5
            ),
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: ClipShape(
                kind: .rectangle,
                color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
                width: 100,
                height: 100
            ),
            text: nil,
            renderOrder: 1
        )

        let center = try renderPixel(clips: [background, foreground], x: 50, y: 50)
        let corner = try renderPixel(clips: [background, foreground], x: 8, y: 8)

        #expect(center[0] > center[2] + 60)
        #expect(corner[2] > corner[0] + 60)
    }

    @MainActor
    @Test func shapeLayerBlendModeUsesTheSharedLayerCompositor() throws {
        let background = shapeDescriptor(
            transform: ClipTransform(),
            color: RGBAColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1),
            width: 100,
            height: 100,
            renderOrder: 0
        )
        let normal = shapeDescriptor(
            transform: ClipTransform(),
            color: RGBAColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
            width: 100,
            height: 100,
            blendMode: .normal,
            renderOrder: 1
        )
        let multiply = shapeDescriptor(
            transform: ClipTransform(),
            color: RGBAColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
            width: 100,
            height: 100,
            blendMode: .multiply,
            renderOrder: 1
        )

        let normalPixel = try renderPixel(clips: [background, normal], x: 50, y: 50)
        let multiplyPixel = try renderPixel(clips: [background, multiply], x: 50, y: 50)

        #expect(normalPixel[0] > multiplyPixel[0] + 10)
        #expect(normalPixel[1] > multiplyPixel[1] + 10)
        #expect(normalPixel[2] > multiplyPixel[2] + 10)
    }

    @Test func projectPosterRendersPersistedCompositedFirstVisibleFrame() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-poster.png")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let shape = ShapeTimelineItem(
            name: "Poster Shape",
            mediaID: MediaID(),
            shape: ClipShape(
                kind: .rectangle,
                color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
                width: 80,
                height: 80
            ),
            timelineStart: 1,
            sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        let project = EditorProject(
            title: "Poster",
            renderSettings: RenderSettings(
                width: 100,
                height: 100,
                frameRate: 30,
                backgroundColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
            ),
            tracks: [
                TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])
            ]
        )

        try await ProjectPosterService(maximumDimension: 100).renderPoster(
            for: project,
            outputURL: outputURL
        )

        let imageData = try Data(contentsOf: outputURL)
        let image = try #require(UIImage(data: imageData)?.cgImage)
        let center = try rgbaPixel(in: image, x: image.width / 2, y: image.height / 2)
        #expect(center[0] > 80)
        #expect(center[1] < 40)
        #expect(center[2] < 40)
    }

    @MainActor
    @Test func textLayerPreservesUnderlyingLayersOutsideGlyphs() throws {
        let background = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: UUID(),
            timelineStart: 0,
            duration: 1,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(),
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(),
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: ClipShape(
                kind: .rectangle,
                color: RGBAColor(red: 0, green: 0, blue: 1, alpha: 1),
                width: 100,
                height: 100
            ),
            text: nil,
            renderOrder: 0
        )
        let text = TextTimelineItem(
            text: "Hi",
            style: TextStyle(fontSize: 28, color: .white),
            layout: TextLayout(widthFraction: 0.8),
            timelineStart: 0,
            duration: 1
        )
        let foreground = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: text.id,
            timelineStart: 0,
            duration: 1,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: text.visuals.transform,
            adjustments: text.visuals.adjustments,
            effectStack: text.visuals.effectStack,
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: nil,
            text: text,
            renderOrder: 1
        )
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            100,
            100,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: String]()
            ] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let destination = try #require(pixelBuffer)

        try MetalFrameRenderer().render(
            plan: FrameRenderPlan(
                renderSize: CGSize(width: 100, height: 100),
                renderScale: 1,
                backgroundColor: .black,
                frameDuration: 1 / 30,
                clips: [background, foreground],
                quality: .export,
                failurePolicy: .failOnUnavailableEffects
            ),
            compositionTime: .zero,
            sourceFrame: { _ in nil },
            destination: destination,
            isCancelled: { false }
        )

        let outsideText = rgbaPixel(in: destination, x: 8, y: 50)
        #expect(outsideText[2] > 80)
        #expect(outsideText[0] < 40)
        #expect(outsideText[1] < 40)
    }

    @MainActor
    @Test func sourceFrameRenderPreservesTopToBottomOrientation() throws {
        let source = try orientedPixelBuffer(width: 64, height: 64)
        let trackID = CMPersistentTrackID(42)
        let descriptor = RenderClipDescriptor(
            trackID: trackID,
            backgroundMaskTrackID: nil,
            clipID: UUID(),
            timelineStart: 0,
            duration: 0.4,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(),
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(),
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: nil,
            text: nil,
            renderOrder: 0
        )
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: String]()
            ] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let destination = try #require(pixelBuffer)

        try MetalFrameRenderer().render(
            plan: FrameRenderPlan(
                renderSize: CGSize(width: 64, height: 64),
                renderScale: 1,
                backgroundColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1),
                frameDuration: 0.1,
                clips: [descriptor],
                quality: .export,
                failurePolicy: .failOnUnavailableEffects
            ),
            compositionTime: CMTime(seconds: 0, preferredTimescale: 600),
            sourceFrame: { $0 == trackID ? source : nil },
            destination: destination,
            isCancelled: { false }
        )

        let top = rgbaPixel(in: destination, x: 32, y: 8)
        let bottom = rgbaPixel(in: destination, x: 32, y: 56)
        #expect(top[0] > top[2])
        #expect(bottom[2] > bottom[0])
    }

    @MainActor
    @Test func effectThumbnailPreviewPreservesAssetOrientation() throws {
        let image = try #require(EffectThumbnailRenderer.originalPreview(for: .cinematicBloom, scale: 1)?.cgImage)

        let top = try rgbaPixel(in: image, x: image.width / 2, y: 24)
        let bottom = try rgbaPixel(in: image, x: image.width / 2, y: image.height - 24)

        #expect(top[2] > bottom[2] + 20)
    }

    @MainActor
    @Test func renderedEffectThumbnailPreservesAssetOrientation() throws {
        let image = try #require(EffectThumbnailRenderer.preview(for: .vignette, scale: 1)?.cgImage)

        let top = try rgbaPixel(in: image, x: image.width / 2, y: 24)
        let bottom = try rgbaPixel(in: image, x: image.width / 2, y: image.height - 24)

        #expect(top[2] > bottom[2] + 20)
    }

    @Test func videoTrackMatricesNormalizeFullDisplayGeometry() async throws {
        let naturalSize = CGSize(width: 1920, height: 1080)
        let transforms = [
            CGAffineTransform.identity,
            CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0),
            CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080),
            CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920),
            CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1920, ty: 0),
            CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1080),
            CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0),
            CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 1080, ty: 1920)
        ]

        for transform in transforms {
            let displayRect = VideoSourceGeometry.displayRect(
                naturalSize: naturalSize,
                transform: transform
            )
            let normalized = CGRect(origin: .zero, size: naturalSize)
                .applying(
                    VideoSourceGeometry.normalizedTransform(
                        naturalSize: naturalSize,
                        transform: transform
                    )
                )
                .standardized

            #expect(abs(normalized.minX) < 0.001)
            #expect(abs(normalized.minY) < 0.001)
            #expect(abs(normalized.width - displayRect.width) < 0.001)
            #expect(abs(normalized.height - displayRect.height) < 0.001)
        }
    }

    @Test func stillImageNormalizationAppliesExifOrientationToStoredPixels() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-oriented.jpg")
        let normalizedURL: URL
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let image = try makeTestImage(width: 2, height: 3)
        guard let destination = CGImageDestinationCreateWithURL(
            sourceURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            Issue.record("Failed to create test image destination")
            return
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation as String: CGImagePropertyOrientation.right.rawValue] as CFDictionary
        )
        #expect(CGImageDestinationFinalize(destination))

        let normalized = try MediaConversionHelper.normalizedStillImageFile(
            at: sourceURL,
            maxPixelSize: 16
        )
        normalizedURL = normalized.url
        defer { try? FileManager.default.removeItem(at: normalizedURL) }

        #expect(Int(normalized.size.width) == 3)
        #expect(Int(normalized.size.height) == 2)

        let decodedSource = try #require(CGImageSourceCreateWithURL(normalizedURL as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(decodedSource, 0, nil))
        #expect(decoded.width == 3)
        #expect(decoded.height == 2)
        let properties = CGImageSourceCopyPropertiesAtIndex(decodedSource, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? Int
        #expect(orientation == nil || orientation == Int(CGImagePropertyOrientation.up.rawValue))
    }

    @Test func portraitVideoTransformDisplaysPortraitWithoutDoubleApplyingMatrix() {
        let naturalSize = CGSize(width: 1920, height: 1080)
        let portraitRight = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let displayRect = VideoSourceGeometry.displayRect(
            naturalSize: naturalSize,
            transform: portraitRight
        )
        let normalized = CGRect(origin: .zero, size: naturalSize)
            .applying(
                VideoSourceGeometry.normalizedTransform(
                    naturalSize: naturalSize,
                    transform: portraitRight
                )
            )
            .standardized

        #expect(abs(displayRect.width - 1080) < 0.001)
        #expect(abs(displayRect.height - 1920) < 0.001)
        #expect(abs(normalized.minX) < 0.001)
        #expect(abs(normalized.minY) < 0.001)
        #expect(abs(normalized.width - 1080) < 0.001)
        #expect(abs(normalized.height - 1920) < 0.001)
    }

    @Test func sourceFitUsesOneSharedScaleForPreviewAndRenderer() throws {
        let renderSize = CGSize(width: 1920, height: 1080)
        let portraitSource = CGSize(width: 1080, height: 1920)
        let fitScale = try #require(
            VideoSourceGeometry.fitScale(sourceSize: portraitSource, inside: renderSize)
        )
        let fitted = try #require(
            VideoSourceGeometry.fittedSize(sourceSize: portraitSource, inside: renderSize)
        )

        #expect(abs(fitScale - 0.5625) < 0.000_001)
        #expect(abs(fitted.width - 607.5) < 0.000_001)
        #expect(abs(fitted.height - 1080) < 0.000_001)
    }

    @Test func generatedLayerClockUsesOneIsolatedVideoTrack() async throws {
        let url = try await MediaConversionHelper.blankVideoClockURL(
            duration: 5,
            frameRate: 30
        )

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let naturalSize = try await track.load(.naturalSize)

        #expect(tracks.count == 1)
        #expect(Int(naturalSize.width.rounded()) == 64)
        #expect(Int(naturalSize.height.rounded()) == 64)
        #expect(abs(CMTimeGetSeconds(try await asset.load(.duration)) - 5) < 0.05)
    }

    @Test func exportSettingsNormalizeEncoderDimensionsAndRates() async throws {
        let settings = VideoExportSettings(
            width: 1_081,
            height: 1_921,
            frameRate: 0,
            videoBitrate: 100,
            audioBitrate: 1_000_000,
            codec: .h264,
            container: .mp4
        ).normalized

        #expect(settings.width == 1_080)
        #expect(settings.height == 1_920)
        #expect(settings.frameRate == 1)
        #expect(settings.videoBitrate == 500_000)
        #expect(settings.audioBitrate == 320_000)
    }

    @MainActor
    @Test func missingDecodedVideoCannotBecomeASuccessfulBlackFrame() throws {
        let clip = RenderClipDescriptor(
            trackID: 1, backgroundMaskTrackID: nil, clipID: UUID(), timelineStart: 0, duration: 1,
            sourceTransform: .identity, backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(), adjustments: AdjustmentSettings(), effectStack: EffectStack(),
            mask: nil, backgroundRemoval: nil, blendMode: .normal, blendIntensity: 1,
            shape: nil, text: nil, renderOrder: 0
        )
        do {
            _ = try renderPixel(clips: [clip], at: 0.5, x: 50, y: 50)
            Issue.record("A missing video source was incorrectly rendered as a valid background")
        } catch MetalRenderingError.sourceFrameUnavailable {
            // The preview adapter retains its last complete composed frame.
        }
        // Actual gaps remain intentional background, rather than replaying
        // content from an unrelated clip on the other side of a cut.
        let gap = try renderPixel(clips: [clip], at: 1.5, x: 50, y: 50,
                                  backgroundColor: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(gap[0] > 200 && gap[1] < 10)
    }

    private func averageAlpha(in rect: CGRect, of image: CIImage) -> UInt8 {
        let average = CIFilter.areaAverage()
        average.inputImage = image.cropped(to: rect)
        guard let averageImage = average.outputImage else { return 255 }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            averageImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        return pixel[3]
    }

    private func averageRGBA(in image: CGImage) throws -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        try pixel.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }

    private func rgbaPixel(in image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        try pixel.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            context.interpolationQuality = .none
            context.translateBy(x: CGFloat(-x), y: CGFloat(y - image.height + 1))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixel
    }

    private func averageRGBA(in pixelBuffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return [0, 0, 0, 0]
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return [0, 0, 0, 0] }

        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var red = 0
        var green = 0
        var blue = 0
        var alpha = 0
        for y in 0..<height {
            let row = bytes + y * bytesPerRow
            for x in 0..<width {
                let pixel = row + x * 4
                blue += Int(pixel[0])
                green += Int(pixel[1])
                red += Int(pixel[2])
                alpha += Int(pixel[3])
            }
        }
        let count = max(width * height, 1)
        return [
            UInt8(red / count),
            UInt8(green / count),
            UInt8(blue / count),
            UInt8(alpha / count)
        ]
    }

    private func rgbaPixel(in pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return [0, 0, 0, 0]
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let clampedX = min(max(x, 0), max(width - 1, 0))
        let clampedY = min(max(y, 0), max(height - 1, 0))
        let pixel = baseAddress
            .advanced(by: clampedY * bytesPerRow + clampedX * 4)
            .assumingMemoryBound(to: UInt8.self)
        return [pixel[2], pixel[1], pixel[0], pixel[3]]
    }

    private func shapeDescriptor(
        transform: ClipTransform,
        color: RGBAColor,
        width: Double = 20,
        height: Double = 20,
        blendMode: BlendMode = .normal,
        renderOrder: Int
    ) -> RenderClipDescriptor {
        RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: UUID(),
            timelineStart: 0,
            duration: 1,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: transform,
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(),
            mask: nil,
            backgroundRemoval: nil,
            blendMode: blendMode,
            blendIntensity: 1,
            shape: ClipShape(
                kind: .rectangle,
                color: color,
                width: width,
                height: height
            ),
            text: nil,
            renderOrder: renderOrder
        )
    }

    @MainActor
    private func renderPixel(
        clips: [RenderClipDescriptor],
        at time: Double = 0,
        x: Int,
        y: Int,
        backgroundColor: RGBAColor = .black,
        livePreviewState: LivePreviewRenderState? = nil,
        renderer: MetalFrameRenderer? = nil
    ) throws -> [UInt8] {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            100,
            100,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: String]()
            ] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let destination = try #require(pixelBuffer)
        try (renderer ?? MetalFrameRenderer()).render(
            plan: FrameRenderPlan(
                renderSize: CGSize(width: 100, height: 100),
                renderScale: 1,
                backgroundColor: backgroundColor,
                frameDuration: 1 / 30,
                clips: clips,
                quality: .export,
                failurePolicy: .failOnUnavailableEffects,
                livePreviewState: livePreviewState
            ),
            compositionTime: CMTime(seconds: time, preferredTimescale: 600),
            sourceFrame: { _ in nil },
            destination: destination,
            isCancelled: { false }
        )
        return rgbaPixel(in: destination, x: x, y: y)
    }

    @MainActor
    private func renderShapeOrderPixel(clips: [RenderClipDescriptor]) throws -> [UInt8] {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            100,
            100,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: String]()
            ] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let destination = try #require(pixelBuffer)
        try MetalFrameRenderer().render(
            plan: FrameRenderPlan(
                renderSize: CGSize(width: 100, height: 100),
                renderScale: 1,
                backgroundColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1),
                frameDuration: 1 / 30,
                clips: clips,
                quality: .export,
                failurePolicy: .failOnUnavailableEffects
            ),
            compositionTime: CMTime(seconds: 0, preferredTimescale: 600),
            sourceFrame: { _ in nil },
            destination: destination,
            isCancelled: { false }
        )
        return rgbaPixel(in: destination, x: 72, y: 40)
    }

    private func orientedPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: String]()
            ] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = base + y * bytesPerRow
            for x in 0..<width {
                let pixel = row + x * 4
                if y < height / 2 {
                    pixel[0] = 0
                    pixel[1] = 0
                    pixel[2] = 255
                    pixel[3] = 255
                } else {
                    pixel[0] = 255
                    pixel[1] = 0
                    pixel[2] = 0
                    pixel[3] = 255
                }
            }
        }
        return buffer
    }

    private func makeTestImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                pixels.append(UInt8(40 + x * 40))
                pixels.append(UInt8(60 + y * 40))
                pixels.append(160)
                pixels.append(255)
            }
        }
        let data = Data(pixels)
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
    }

    private func writeSolidImage(
        _ color: UIColor,
        to url: URL,
        modificationOffset: TimeInterval
    ) throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        try #require(image.pngData()).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: modificationOffset)],
            ofItemAtPath: url.path
        )
    }

    private func renderStillAverage(
        url: URL,
        cacheIdentity: String,
        renderer: MetalFrameRenderer
    ) throws -> [UInt8] {
        let descriptor = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            stillImageURL: url,
            stillImageCacheIdentity: cacheIdentity,
            clipID: UUID(),
            timelineStart: 0,
            duration: 1,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(),
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(),
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: nil,
            text: nil,
            renderOrder: 0
        )
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: String]()
            ] as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let destination = try #require(pixelBuffer)

        try renderer.render(
            plan: FrameRenderPlan(
                renderSize: CGSize(width: 16, height: 16),
                renderScale: 1,
                backgroundColor: .black,
                frameDuration: 1 / 30,
                clips: [descriptor],
                quality: .export,
                failurePolicy: .failOnUnavailableEffects
            ),
            compositionTime: .zero,
            sourceFrame: { _ in nil },
            destination: destination,
            isCancelled: { false }
        )
        return averageRGBA(in: destination)
    }

    @MainActor
    @Test func originalRatioUsesSelectedVisualClipSizeAndPreservesFrameRate() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Landscape",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/landscape.mov"),
                mediaType: .video,
                originalDuration: 2,
                naturalSize: CGSizeValue(width: 1280, height: 720)
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Original Ratio",
            renderSettings: RenderSettings(width: 1080, height: 1920, frameRate: 60),
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)
        viewModel.setCanvasToSelectedClipOriginalRatio()

        #expect(viewModel.project.renderSettings.width == 1280)
        #expect(viewModel.project.renderSettings.height == 720)
        #expect(viewModel.project.renderSettings.frameRate == 60)
        #expect(viewModel.undoStack.last?.invalidation.contains(.compositionTopology) == true)
    }

    @Test func emptyProjectCompositionIsValidAndVideoFree() async throws {
        let project = EditorProject.empty(title: "Empty")
        let rendered = try await CompositionRenderService().makeComposition(for: project)

        #expect(rendered.duration == 0)
        #expect(rendered.hasVideo == false)
        #expect(rendered.videoComposition == nil)
    }

    @Test func textRendererKeepsMultilineGeometryStableDuringTypewriterReveal() async throws {
        let style = TextStyle(
            fontName: "Missing-Font-Falls-Back",
            fontSize: 42,
            color: .white,
            alignment: .trailing,
            letterSpacing: 2,
            lineSpacing: 7,
            stroke: TextStrokeStyle(width: 3),
            shadow: TextShadowStyle(offsetX: 4, offsetY: 5, blur: 8),
            background: TextBackgroundStyle(padding: 14, cornerRadius: 10)
        )
        let multiline = TextTimelineItem(
            text: "First line\nSecond line",
            style: style,
            layout: TextLayout(widthFraction: 0.7),
            timelineStart: 0,
            duration: 2
        )
        let singleLine = TextTimelineItem(
            text: "First line",
            style: style,
            layout: TextLayout(widthFraction: 0.7),
            timelineStart: 0,
            duration: 2
        )
        let renderer = TextLayerRenderer()
        let hidden = renderer.render(
            item: multiline,
            renderSize: CGSize(width: 600, height: 800),
            renderScale: 1,
            glyphReveal: 0
        )
        let visible = renderer.render(
            item: multiline,
            renderSize: CGSize(width: 600, height: 800),
            renderScale: 1,
            glyphReveal: 1
        )
        let singleGeometry = TextLayerRenderer.geometry(
            for: singleLine,
            renderSize: CGSize(width: 600, height: 800),
            renderScale: 1
        )

        #expect(hidden.geometry == visible.geometry)
        #expect(visible.geometry.layerSize.height > singleGeometry.layerSize.height)
        #expect(abs(visible.geometry.backgroundRect!.width - 420) < 0.001)
        #expect(
            TextLayerRenderer.resolvedFont(for: style, renderScale: 1).fontName
                == UIFont.systemFont(ofSize: 42, weight: .semibold).fontName
        )
    }

    @Test func textOnlyCompositionGetsTemporaryVideoClock() async throws {
        let text = TextTimelineItem(
            text: "Text only",
            timelineStart: 0,
            duration: 0.2
        )
        let project = EditorProject(
            title: "Text only",
            renderSettings: RenderSettings(width: 96, height: 128, frameRate: 10),
            tracks: [
                TimelineTrack(
                    name: "Text 1",
                    kind: .text,
                    items: [.text(text)]
                )
            ]
        )

        let rendered = try await CompositionRenderService().makeComposition(for: project)

        #expect(rendered.hasVideo)
        #expect(rendered.videoComposition != nil)
        #expect(rendered.videoClockTrackID != nil)
        #expect(!rendered.composition.tracks(withMediaType: .video).isEmpty)
    }

    @Test func videoSourceAudioStaysInTopologyIndependentlyOfItsEnvelope() {
        #expect(CompositionAudioPolicy.includesSourceAudio(for: .video))
        #expect(!CompositionAudioPolicy.includesSourceAudio(for: .image))
        #expect(!CompositionAudioPolicy.includesSourceAudio(for: .audio))
    }

    @Test func rasterPixelBudgetBoundsExtremeGeneratedScales() {
        let logicalSize = CGSize(width: 4_000, height: 4_000)
        let bounded = GeneratedRasterPolicy.boundedRasterScale(
            CGSize(width: 10, height: 10), logicalSize: logicalSize)
        let pixels = logicalSize.width * bounded.width * logicalSize.height * bounded.height
        #expect(pixels <= GeneratedRasterPolicy.maximumRasterizedPixelCount + 1)
        #expect(bounded.width >= 1 && bounded.height >= 1)
    }

    @MainActor
    @Test func previewRenderSizeBindsToPhysicalDisplaySize() async throws {
        func shapeProject() -> EditorProject {
            let item = ShapeTimelineItem(
                name: "Shape", mediaID: MediaID(),
                shape: ClipShape(kind: .rectangle, color: .white, width: 400, height: 225),
                timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 1))
            return EditorProject(
                title: "Display sized preview",
                renderSettings: RenderSettings(width: 1_920, height: 1_080, frameRate: 30),
                tracks: [TimelineTrack(name: "Shape", kind: .shape, items: [.shape(item)])]
            )
        }
        let service = CompositionRenderService()
        let unbound = try #require(
            try await service.preparePreview(
                for: shapeProject(), quality: .balanced,
                invalidation: [.previewFrame, .compositionTopology]))
        #expect(unbound.videoComposition?.renderSize == CGSize(width: 960, height: 540))
        let unboundInstruction = try #require(
            unbound.videoComposition?.instructions.first as? MotionaryVideoCompositionInstruction)
        #expect(abs(unboundInstruction.vectorRenderScale - 0.75) < 0.001)
        let bound = try #require(
            try await service.preparePreview(
                for: shapeProject(), quality: .balanced,
                invalidation: [.previewFrame, .compositionTopology],
                displayPixelSize: CGSize(width: 640, height: 360)))
        #expect(bound.videoComposition?.renderSize == CGSize(width: 640, height: 360))
        let boundInstruction = try #require(
            bound.videoComposition?.instructions.first as? MotionaryVideoCompositionInstruction)
        #expect(abs(boundInstruction.vectorRenderScale - (CGFloat(640) / CGFloat(1920))) < 0.001)
        #expect(abs(boundInstruction.renderScale - (CGFloat(640) / CGFloat(1920))) < 0.001)
    }
}
