@preconcurrency import AVFoundation
import CoreImage
import Testing
import UIKit
@testable import Motionary

@Suite(.serialized)
struct DepthMapEffectTests {
    @Test func rendersBundledModelAsGrayscale() throws {
        let image = try #require(UIImage(named: "EffectsShowcaseEssentials")?.cgImage)
        let source = CIImage(cgImage: image)
        let effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .depthMap))
        let renderer = try MetalFrameRenderer()
        let output = try renderer.renderEffectsSynchronously(
            EffectStack(effects: [effect]), to: source, at: 0, renderScale: 1, quality: .export)
        #expect(output.extent == source.extent)
        let small = output.transformed(by: CGAffineTransform(scaleX: 32 / output.extent.width, y: 32 / output.extent.height))
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        CIContext().render(small, toBitmap: &pixels, rowBytes: 32 * 4,
            bounds: CGRect(x: 0, y: 0, width: 32, height: 32), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let luminance = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
        #expect(Int(luminance.max() ?? 0) > Int(luminance.min() ?? 0) + 5)
        let isGrayscale = stride(from: 0, to: pixels.count, by: 4).allSatisfy { index in
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            return abs(red - green) <= 1 && abs(red - blue) <= 1 && pixels[index + 3] == 255
        }
        #expect(isGrayscale)
    }
    @Test func libraryPreviewMatchesOriginalDimensionsAndLegacyStyleFallsBack() throws {
        let original = try #require(EffectThumbnailRenderer.originalPreview(for: .depthMap))
        let depth = try #require(EffectThumbnailRenderer.preview(for: .depthMap))
        #expect(original.size == depth.size)
        var effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .depthMap))
        effect.parameters["depthStyle"] = EffectParameterState(baseValue: .option("Source mix"))
        #expect(EffectRegistry.shared.resolvedValue(for: "depthStyle", in: effect, at: 0) == .option("Grayscale"))
    }

    @MainActor
    @Test func completedDepthPreparationClearsProgressDuringPreviewRebuild() {
        let model = EditorViewModel(projectID: UUID(), projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: EditorProject(title: "Depth progress")))
        defer { model.stop() }
        let id = UUID()
        model.isRenderingPreview = true
        model.handleDepthPreparationProgress(Notification(name: DepthBakeStore.preparationProgress,
            userInfo: ["id": id, "progress": 1.0]))
        model.handleDepthPreparationProgress(Notification(name: DepthBakeStore.preparationProgress,
            userInfo: ["id": id]))
        #expect(model.depthPreparationProgress == nil)
        #expect(model.depthPreparationID == nil)
    }

    @Test func storedStillDepthPreservesModelCoordinates() throws {
        let image = CIImage(cgImage: try #require(UIImage(named: "EffectsShowcaseEssentials")?.cgImage))
        let width = DepthBakeStore.width, height = DepthBakeStore.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let context = CIContext(options: [.cacheIntermediates: false])
        let fitted = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width,
                                                y: CGFloat(height) / image.extent.height))
        var input: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
            &input) == kCVReturnSuccess)
        context.render(fitted, to: try #require(input), bounds: bounds,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let predicted = CIImage(cvPixelBuffer: try DepthModel.shared.predict(try #require(input)))
        let stored = try DepthBakeStore.shared.still(image, effectID: UUID())
        let rowBytes = (width + 3) / 4 * 4
        func pixels(_ image: CIImage) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: rowBytes * height)
            context.render(image, toBitmap: &result, rowBytes: rowBytes, bounds: bounds,
                           format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
            return result
        }
        // Compare against the model's image buffer directly. Applying the
        // production orientation helper here would hide a mirrored result.
        let expected = pixels(predicted), actual = pixels(stored)
        let directError = zip(expected, actual).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        let flippedError = (0..<height).reduce(0) { total, y in
            total + (0..<width).reduce(0) { $0 + abs(Int(expected[y * rowBytes + $1]) - Int(actual[y * rowBytes + (width - 1 - $1)])) }
        }
        #expect(directError < flippedError)
        #expect(Double(directError) / Double(width * height) < 1)
    }

    @MainActor
    @Test func stoppingDepthPreparationRemovesOnlyThePreparingEffect() throws {
        let shape = ShapeTimelineItem(
            name: "Shape", mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle, color: .white, width: 64, height: 64),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let track = TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])
        let project = EditorProject(title: "Depth cancellation",
            renderSettings: RenderSettings(width: 96, height: 128, frameRate: 30), tracks: [track])
        let model = EditorViewModel(projectID: UUID(), projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project))
        defer { model.stop() }
        model.selectTimelineItem(shape.id, trackID: track.id)
        let effectID = try #require(model.addEffect(moduleID: .depthMap))
        let preparationID = UUID()
        model.depthPreparationID = preparationID
        model.depthPreparationEffectID = effectID
        model.depthPreparationProgress = 0.3

        model.cancelLongRunningTask()

        let effects = try #require(model.indexedTimelineItem(id: shape.id)?.visualEditingClip()?.effectStack.effects)
        #expect(!effects.contains { $0.id == effectID })
        #expect(model.depthPreparationProgress == nil)
        #expect(model.cancelledDepthPreparationID == preparationID)
        #expect(model.rebuildTask != nil)
    }

    @Test func temporalFilterRejectsCutsAndMovingEdges() {
        let stable = DepthBakeStore.stabilized([100, 100], previous: [90, 90], next: [90, 90], strength: 0.8)
        #expect(stable == [92, 92])
        #expect(DepthBakeStore.stabilized([100], previous: [0], next: [255], strength: 1) == [100])
        #expect(DepthBakeStore.stabilized([100], previous: [90], next: [90], strength: 0) == [100])
    }

    private func makeDepthVideo() async throws -> (url: URL, fitted: CIImage) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("depth-test-\(UUID()).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let original = CIImage(cgImage: try #require(UIImage(named: "EffectsShowcaseEssentials")?.cgImage))
        let fitted = original.transformed(by: CGAffineTransform(scaleX: 320 / original.extent.width, y: 240 / original.extent.height))
        for index in 0..<4 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var buffer: CVPixelBuffer?
            let pool = try #require(adaptor.pixelBufferPool)
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let frame = try #require(buffer)
            CIContext().render(fitted, to: frame)
            #expect(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 24)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return (url, fitted)
    }

    @Test func depthPreparationAcceptsATrimExtendingPastTheVideoTrack() async throws {
        let (url, _) = try await makeDepthVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let end = try await track.load(.timeRange).end.seconds
        let source = EffectTemporalSource(url: url, sourceStart: end - 2.0 / 24,
            sourceDuration: 5.0 / 24, speedMap: .constant(speed: 1.5))
        let effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .depthMap))

        try await DepthBakeStore.prepare(source: source, effect: effect)
        let count = DepthModel.shared.predictionCount
        let time = source.speedMap.timelineDuration(sourceDuration: source.sourceDuration)
        let image = try DepthBakeStore.shared.image(source: source, effect: effect, time: time)
        #expect(image.extent.width == CGFloat(DepthBakeStore.width))
        #expect(image.extent.height == CGFloat(DepthBakeStore.height))
        #expect(DepthModel.shared.predictionCount == count)
    }

    @Test func bakedVideoScrubsWithoutInferenceAndReusesAnalysisForStyleChanges() async throws {
        let (url, fitted) = try await makeDepthVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = EffectTemporalSource(url: url, sourceStart: 0, sourceDuration: 4.0 / 24, speedMap: .constant(speed: 1))
        var effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .depthMap))
        try await DepthBakeStore.prepare(source: source, effect: effect)
        let count = DepthModel.shared.predictionCount
        let bakedMap = try DepthBakeStore.shared.image(source: source, effect: effect, time: 0.04)
        let stillMap = try DepthBakeStore.shared.still(VideoSourceGeometry.engineImage(fitted), effectID: UUID())
        let sampleBounds = CGRect(x: 0, y: 0, width: 32, height: 24)
        func mapPixels(_ image: CIImage) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: 32 * 24)
            let scaled = image.transformed(by: CGAffineTransform(
                scaleX: 32 / image.extent.width, y: 24 / image.extent.height))
            CIContext().render(scaled, toBitmap: &pixels, rowBytes: 32, bounds: sampleBounds,
                format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
            return pixels
        }
        let videoPixels = mapPixels(bakedMap), stillPixels = mapPixels(stillMap)
        let direct = zip(videoPixels, stillPixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        var mirrored = 0
        for y in 0..<24 {
            for x in 0..<32 {
                mirrored += abs(Int(videoPixels[y * 32 + x]) - Int(stillPixels[y * 32 + 31 - x]))
            }
        }
        #expect(direct < mirrored, "Still and video depth must use the same spatial coordinates")
        let countAfterStill = DepthModel.shared.predictionCount
        let renderer = try MetalFrameRenderer()
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 240)
        func pixels(at time: Double) throws -> [UInt8] {
            let output = try renderer.renderEffectsSynchronously(EffectStack(effects: [effect]),
                to: fitted, at: time, renderScale: 1, quality: .interactive, temporalSource: source)
            var pixels = [UInt8](repeating: 0, count: 320 * 240 * 4)
            CIContext().render(output, toBitmap: &pixels, rowBytes: 320 * 4, bounds: bounds,
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return pixels
        }
        let first = try pixels(at: 0.04)
        let later = try pixels(at: 0.11)
        #expect(try pixels(at: 0.04) == first)
        #expect(stride(from: 3, to: first.count, by: 4).allSatisfy { first[$0] == 255 && later[$0] == 255 })
        effect.parameters["depthStyle"] = EffectParameterState(baseValue: .option("Thermal"))
        try await DepthBakeStore.prepare(source: source, effect: effect)
        #expect(DepthModel.shared.predictionCount == countAfterStill)
        var resizedSource = source
        resizedSource.sourceOrientation = CGAffineTransform(scaleX: 2, y: 2)
        try await DepthBakeStore.prepare(source: resizedSource, effect: effect)
        #expect(DepthModel.shared.predictionCount == countAfterStill)
        #expect(countAfterStill >= count)
        #expect(try pixels(at: 0.04) != first)
        var second = try #require(EffectRegistry.shared.makeEffect(moduleID: .depthMap))
        second.parameters["depthStability"] = EffectParameterState(baseValue: .option("High"))
        let descriptor = RenderClipDescriptor(trackID: 42, backgroundMaskTrackID: nil, clipID: UUID(), timelineStart: 0,
            duration: 4.0 / 24, sourceTransform: .identity, backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(), adjustments: AdjustmentSettings(), effectStack: EffectStack(effects: [effect, second]),
            mask: nil, backgroundRemoval: nil, blendMode: .normal, blendIntensity: 1, shape: nil, text: nil,
            renderOrder: 0, temporalSource: source)
        try await DepthBakeStore.prepare([descriptor])
        let preparedCount = DepthModel.shared.predictionCount
        _ = try DepthBakeStore.shared.image(source: source, effect: second, time: 0.04)
        #expect(DepthModel.shared.predictionCount == preparedCount)
    }

}
