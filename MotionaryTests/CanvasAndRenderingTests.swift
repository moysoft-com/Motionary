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

@Suite(.serialized)
struct CanvasAndRenderingTests {
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
        let base = renderer.render(
            item: item,
            renderSize: renderSize,
            renderScale: 0.5,
            rasterScaleMultiplier: 1
        )
        let supersampled = renderer.render(
            item: item,
            renderSize: renderSize,
            renderScale: 0.5,
            rasterScaleMultiplier: 2
        )

        #expect(base.geometry == supersampled.geometry)
        #expect(abs(supersampled.image.extent.width - base.image.extent.width * 2) <= 1)
        #expect(abs(supersampled.image.extent.height - base.image.extent.height * 2) <= 1)
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
    @Test func generatedCanvasLayersKeepFullPreviewRenderSize() async throws {
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

        #expect(prepared?.videoComposition?.renderSize == CGSize(width: 1080, height: 1920))
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
        let resolved = descriptor.resolvingLiveOverride(from: plan.livePreviewState)

        #expect(plan.clipIntervals.count == instruction.clipIntervals.count)
        #expect(plan.renderScale == 0.5)
        #expect(plan.vectorRenderScale == 1)
        #expect(plan.viewport.visibleRect == CGRect(x: 0, y: 0, width: 1080, height: 1920))
        #expect(plan.viewport.overscanRect.contains(plan.viewport.visibleRect))
        #expect(plan.livePreviewState === liveState)
        #expect(plan.quality == .interactive)
        #expect(resolved.transform.positionX.baseValue == 0.42)
        #expect(descriptor.transform.positionX.baseValue == 0)

        liveState.setHidden(true, for: text.id)
        liveState.revealPreservingTransform(for: text.id)

        #expect(liveState.isHidden(text.id) == false)
        #expect(liveState.transform(for: text.id)?.positionX.baseValue == 0.42)
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
    @Test func stillImageCacheInvalidatesWhenFileChangesAtSameURL() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-mutable-still.png")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try writeSolidImage(.systemRed, to: sourceURL, modificationOffset: 10)
        let renderer = try MetalFrameRenderer()
        let first = try renderStillAverage(url: sourceURL, renderer: renderer)
        try writeSolidImage(.systemBlue, to: sourceURL, modificationOffset: 20)
        let second = try renderStillAverage(url: sourceURL, renderer: renderer)

        #expect(first[0] > first[2])
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
        let image = try #require(EffectThumbnailRenderer.originalPreview(scale: 1)?.cgImage)

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
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let naturalSize = try await track.load(.naturalSize)

        #expect(tracks.count == 1)
        #expect(Int(naturalSize.width.rounded()) == 2)
        #expect(Int(naturalSize.height.rounded()) == 2)
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
            blendMode: .normal,
            blendIntensity: 1,
            shape: ClipShape(
                kind: .rectangle,
                color: color,
                width: 20,
                height: 20
            ),
            text: nil,
            renderOrder: renderOrder
        )
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
        renderer: MetalFrameRenderer
    ) throws -> [UInt8] {
        let descriptor = RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            stillImageURL: url,
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
}
