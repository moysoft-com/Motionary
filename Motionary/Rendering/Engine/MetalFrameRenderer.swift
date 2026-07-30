@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Metal
import os
import UIKit

/// Owns the complete GPU frame graph. The AVFoundation compositor only adapts
/// asynchronous requests into this synchronous, bounded render operation.
final class MetalFrameRenderer: @unchecked Sendable {
    typealias SourceFrameProvider = (CMPersistentTrackID) -> CVPixelBuffer?

    private let resources: MetalRenderResources
    private let effectRegistry: EffectRenderRegistry
    private let textLayerRenderer = TextLayerRenderer()
    private let rasterizationLock = NSLock()
    private let signpostLog = OSLog(
        subsystem: "com.moysoft.motionary",
        category: .pointsOfInterest
    )

    private final class CachedGPUImage: NSObject {
        let image: CIImage
        let texture: MTLTexture

        init(image: CIImage, texture: MTLTexture) {
            self.image = image
            self.texture = texture
        }
    }

    private let maskImageCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 32
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()

    private let gpuImageCache: NSCache<NSString, CachedGPUImage> = {
        let cache = NSCache<NSString, CachedGPUImage>()
        cache.countLimit = 64
        cache.totalCostLimit = GeneratedRasterPolicy.gpuImageCacheBytes
        return cache
    }()

    private let heartMaskSymbols: (normal: UIImage?, inverted: UIImage?) = {
        let configuration = UIImage.SymbolConfiguration(
            pointSize: 256,
            weight: .regular,
            scale: .large
        )
        let symbol = UIImage(systemName: "heart.fill", withConfiguration: configuration)
        return (
            symbol?.withTintColor(.white, renderingMode: .alwaysOriginal),
            symbol?.withTintColor(.black, renderingMode: .alwaysOriginal)
        )
    }()

    init(
        resources: MetalRenderResources? = nil,
        effectRegistry: EffectRenderRegistry = .shared
    ) throws {
        self.resources = try resources ?? MetalRenderResources.shared()
        self.effectRegistry = effectRegistry
    }

    func render(
        plan: FrameRenderPlan,
        compositionTime: CMTime,
        sourceFrame: SourceFrameProvider,
        destination: CVPixelBuffer,
        isCancelled: () -> Bool
    ) throws {
        let frameResources = try encodeFrame(
            plan: plan,
            compositionTime: compositionTime,
            sourceFrame: sourceFrame,
            destination: destination,
            isCancelled: isCancelled
        )
        try frameResources.commitAndWait()
        guard !isCancelled() else { throw MetalRenderingError.cancelled }
    }

    func renderAsync(
        plan: FrameRenderPlan,
        compositionTime: CMTime,
        sourceFrame: SourceFrameProvider,
        destination: CVPixelBuffer,
        isCancelled: @escaping () -> Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            let frameResources = try encodeFrame(
                plan: plan,
                compositionTime: compositionTime,
                sourceFrame: sourceFrame,
                destination: destination,
                isCancelled: isCancelled
            )
            frameResources.commit { result in
                switch result {
                case .success:
                    guard !isCancelled() else {
                        completion(.failure(MetalRenderingError.cancelled))
                        return
                    }
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    private func encodeFrame(
        plan: FrameRenderPlan,
        compositionTime: CMTime,
        sourceFrame: SourceFrameProvider,
        destination: CVPixelBuffer,
        isCancelled: () -> Bool
    ) throws -> MetalFrameResources {
        guard !isCancelled() else { throw MetalRenderingError.cancelled }
        let frameResources = try resources.beginFrame()
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "Render Frame", signpostID: signpostID)
        defer {
            os_signpost(.end, log: signpostLog, name: "Render Frame", signpostID: signpostID)
        }

        do {
            let time = CMTimeGetSeconds(compositionTime)
            let safeTime = time.isFinite ? time : 0
            let frameDuration = max(plan.frameDuration, 1 / 600)
            let frameIndex = Int64((safeTime / frameDuration).rounded(.toNearestOrAwayFromZero))
            let canvasRect = CGRect(origin: .zero, size: plan.renderSize)
            let backgroundColor = CIColor(
                red: plan.backgroundColor.red,
                green: plan.backgroundColor.green,
                blue: plan.backgroundColor.blue,
                alpha: plan.backgroundColor.alpha,
                colorSpace: resources.generatedColorSpace
            ) ?? CIColor.black
            var output = CIImage(color: backgroundColor).cropped(to: canvasRect)

            for clip in activeClips(in: plan, at: safeTime) {
                guard !isCancelled() else { throw MetalRenderingError.cancelled }
                let localTime = max(0, safeTime - clip.timelineStart)
                let isGeneratedLayer = clip.shape != nil || clip.text != nil
                let cullingMargin = max(plan.renderSize.width, plan.renderSize.height) * 0.25
                if isGeneratedLayer,
                    let estimatedBounds = estimatedGeneratedPlacementBounds(
                        for: clip,
                        at: localTime,
                        plan: plan
                    ),
                    !estimatedBounds.insetBy(dx: -cullingMargin, dy: -cullingMargin)
                        .intersects(plan.viewport.overscanRect)
                {
                    continue
                }
                let sourceResult = try measured("Source Pass", id: signpostID) {
                    try makeSourceImage(
                        for: clip,
                        localTime: localTime,
                        plan: plan,
                        sourceFrame: sourceFrame,
                        resources: frameResources
                    )
                }
                guard var image = sourceResult.image else { continue }
                let placementExtent = image.extent
                let projectedBounds = projectedPlacementBounds(
                    placementExtent: placementExtent,
                    clip: clip,
                    at: localTime,
                    renderSize: plan.renderSize,
                    isGeneratedLayer: isGeneratedLayer,
                    rasterScaleCorrection: sourceResult.rasterScaleCorrection,
                    textAnimationSample: sourceResult.textAnimationSample
                )
                guard projectedBounds.insetBy(dx: -cullingMargin, dy: -cullingMargin)
                    .intersects(plan.viewport.overscanRect)
                else { continue }

                image = try measured("Adjustments and Effects", id: signpostID) {
                    let adjusted = applyAdjustments(clip.adjustments, to: image, at: localTime)
                    return try effectRegistry.render(
                        clip.effectStack,
                        to: adjusted,
                        context: EffectRenderContext(
                            compositionTime: safeTime,
                            clipTime: localTime,
                            frameIndex: frameIndex,
                            itemID: clip.clipID,
                            renderScale: plan.renderScale,
                            quality: plan.quality
                        ),
                        resources: frameResources,
                        failurePolicy: plan.failurePolicy
                    )
                }
                image = measured("Mask and Transform", id: signpostID) {
                    var transformed = image
                    if let textSample = sourceResult.textAnimationSample {
                        transformed = applyClipReveal(textSample.clipReveal, to: transformed)
                    }
                    transformed = applyMask(clip.mask, to: transformed)
                    transformed = place(
                        transformed,
                        placementExtent: placementExtent,
                        clip: clip,
                        at: localTime,
                        renderSize: plan.renderSize,
                        isGeneratedLayer: isGeneratedLayer,
                        rasterScaleCorrection: sourceResult.rasterScaleCorrection,
                        textAnimationSample: sourceResult.textAnimationSample
                    )
                    var opacity = min(max(clip.transform.opacity.value(at: localTime), 0), 1)
                    opacity *= sourceResult.textAnimationSample?.opacity ?? 1
                    return applyOpacity(opacity, to: transformed)
                }
                output = try measured("Blend Pass", id: signpostID) {
                    try MetalLayerCompositor.blend(
                        foreground: image,
                        background: output,
                        in: canvasRect,
                        mode: clip.blendMode,
                        intensity: clip.blendIntensity,
                        resources: frameResources
                    )
                }
            }

            guard !isCancelled() else { throw MetalRenderingError.cancelled }
            try measured("Output Pass", id: signpostID) {
                let destinationTexture = try frameResources.makeDestinationTexture(from: destination)
                resources.ciContext.render(
                    output.cropped(to: canvasRect),
                    to: destinationTexture,
                    commandBuffer: frameResources.commandBuffer,
                    bounds: canvasRect,
                    colorSpace: resources.outputColorSpace
                )
            }
            attachRec709Metadata(to: destination)
            return frameResources
        } catch {
            frameResources.abandon()
            throw error
        }
    }

    func renderEffectsSynchronously(
        _ stack: EffectStack,
        to image: CIImage,
        at time: Double,
        renderScale: CGFloat,
        quality: RenderQualityProfile = .balanced
    ) throws -> CIImage {
        let frame = try resources.beginFrame()
        let sourceExtent = image.extent.integral
        let output = try effectRegistry.render(
            stack,
            to: image,
            context: EffectRenderContext(
                compositionTime: time,
                clipTime: time,
                frameIndex: Int64((time * 30).rounded()),
                itemID: UUID(uuidString: "3F205CA2-736B-4DDD-A420-4E57033F9991")!,
                renderScale: renderScale,
                quality: quality
            ),
            resources: frame,
            failurePolicy: .skipUnavailableEffects
        )
        let outputExtent = output.extent.integral.union(sourceExtent)
        let width = max(Int(outputExtent.width), 1)
        let height = max(Int(outputExtent.height), 1)
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
        guard status == kCVReturnSuccess, let pixelBuffer else {
            frame.abandon()
            throw MetalRenderingError.pixelBufferTextureCreationFailed(status)
        }
        let destinationTexture = try frame.makeDestinationTexture(from: pixelBuffer)
        let localOutput = output.transformed(by: CGAffineTransform(
            translationX: -outputExtent.minX,
            y: -outputExtent.minY
        ))
        resources.ciContext.render(
            localOutput,
            to: destinationTexture,
            commandBuffer: frame.commandBuffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: resources.outputColorSpace
        )
        try frame.commitAndWait()
        let localImage = CIImage(
            cvPixelBuffer: pixelBuffer,
            options: [.colorSpace: resources.outputColorSpace]
        )
        let uprightLocalImage = localImage.transformed(
            by: CGAffineTransform(translationX: 0, y: CGFloat(height))
                .scaledBy(x: 1, y: -1)
        )
        return uprightLocalImage
            .transformed(by: CGAffineTransform(
                translationX: outputExtent.minX,
                y: outputExtent.minY
            ))
            .cropped(to: outputExtent)
    }

    func purgeCaches() {
        rasterizationLock.lock()
        maskImageCache.removeAllObjects()
        gpuImageCache.removeAllObjects()
        textLayerRenderer.removeAllObjects()
        rasterizationLock.unlock()
        resources.purgeCaches()
    }

    func renderShapeLayer(
        _ shape: ClipShape,
        at time: Double,
        logicalRenderScale: CGFloat,
        rasterScale: CGSize
    ) throws -> CIImage {
        try shapeImage(
            shape,
            at: time,
            renderScale: logicalRenderScale,
            rasterScale: rasterScale
        )
    }

    func renderShapeLayer(
        _ shape: ClipShape,
        at time: Double,
        logicalRenderScale: CGFloat,
        rasterScaleMultiplier: CGFloat
    ) throws -> CIImage {
        try renderShapeLayer(
            shape,
            at: time,
            logicalRenderScale: logicalRenderScale,
            rasterScale: CGSize(width: rasterScaleMultiplier, height: rasterScaleMultiplier)
        )
    }

    private struct SourceResult {
        let image: CIImage?
        let textAnimationSample: TextAnimationSample?
        let rasterScaleCorrection: CGSize
    }

    private func generatedLayerRasterScale(
        for plan: FrameRenderPlan,
        clip: RenderClipDescriptor,
        at time: Double,
        textAnimationSample: TextAnimationSample? = nil,
        baseSize: CGSize? = nil
    ) -> CGSize {
        let scale = clip.transform.scale.value(at: time)
        let animationScale = textAnimationSample?.scale ?? 1
        let transformScale = CGSize(
            width: max(abs(CGFloat(scale.x)) * max(CGFloat(animationScale), 0.000_001), 1),
            height: max(abs(CGFloat(scale.y)) * max(CGFloat(animationScale), 0.000_001), 1)
        )
        let qualityScale = max(plan.vectorRenderScale / max(plan.renderScale, 0.000_001), 1)
        if let baseSize {
            return GeneratedRasterPolicy.generatedLayerRasterScale(
                transformScale: transformScale,
                qualityScale: qualityScale,
                logicalSize: baseSize,
                renderSize: plan.renderSize,
                maximumTextureDimension: generatedLayerMaximumTextureDimension(for: plan)
            )
        }
        return CGSize(
            width: max(transformScale.width, qualityScale, 1),
            height: max(transformScale.height, qualityScale, 1)
        )
    }

    private func generatedLayerMaximumTextureDimension(for plan: FrameRenderPlan) -> Int {
        switch plan.quality {
        case .interactive:
            return GeneratedRasterPolicy.interactiveMaximumTextureDimension
        case .balanced, .export:
            return GeneratedRasterPolicy.maximumTextureDimension
        }
    }

    private func estimatedGeneratedPlacementBounds(
        for clip: RenderClipDescriptor,
        at localTime: Double,
        plan: FrameRenderPlan
    ) -> CGRect? {
        if let shape = clip.shape {
            let layout = ShapeRasterLayout(
                shape: shape,
                at: localTime,
                logicalRenderScale: plan.renderScale,
                rasterScaleMultiplier: 1
            )
            return projectedPlacementBounds(
                placementExtent: CGRect(origin: .zero, size: layout.logicalSize),
                clip: clip,
                at: localTime,
                renderSize: plan.renderSize,
                isGeneratedLayer: true,
                rasterScaleCorrection: CGSize(width: 1, height: 1),
                textAnimationSample: nil
            )
        }

        if let text = clip.text {
            let sample = TextAnimationEvaluator.sample(
                animations: text.animations,
                at: localTime,
                clipDuration: text.duration
            )
            let geometry = TextLayerRenderer.geometry(
                for: text,
                renderSize: plan.renderSize,
                renderScale: plan.renderScale,
                at: localTime
            )
            return projectedPlacementBounds(
                placementExtent: CGRect(origin: .zero, size: geometry.layerSize),
                clip: clip,
                at: localTime,
                renderSize: plan.renderSize,
                isGeneratedLayer: true,
                rasterScaleCorrection: CGSize(width: 1, height: 1),
                textAnimationSample: sample
            )
        }

        return nil
    }

    private func makeSourceImage(
        for clip: RenderClipDescriptor,
        localTime: Double,
        plan: FrameRenderPlan,
        sourceFrame: SourceFrameProvider,
        resources frameResources: MetalFrameResources
    ) throws -> SourceResult {
        let generatedSourceTime = generatedLayerSourceSampleTime(localTime, plan: plan)
        if let shape = clip.shape {
            let baseLayout = ShapeRasterLayout(
                shape: shape,
                at: generatedSourceTime,
                logicalRenderScale: plan.renderScale,
                rasterScaleMultiplier: 1
            )
            let generatedRasterScale = generatedLayerRasterScale(
                for: plan,
                clip: clip,
                at: generatedSourceTime,
                baseSize: baseLayout.logicalSize
            )
            let generatedScaleCorrection = CGSize(
                width: 1 / max(generatedRasterScale.width, 0.000_001),
                height: 1 / max(generatedRasterScale.height, 0.000_001)
            )
            return SourceResult(
                image: try shapeImage(
                    shape,
                    at: generatedSourceTime,
                    renderScale: plan.renderScale,
                    rasterScale: generatedRasterScale
                ),
                textAnimationSample: nil,
                rasterScaleCorrection: generatedScaleCorrection
            )
        }
        if let text = clip.text {
            let sample = TextAnimationEvaluator.sample(
                animations: text.animations,
                at: generatedSourceTime,
                clipDuration: text.duration
            )
            let baseGeometry = TextLayerRenderer.geometry(
                for: text,
                renderSize: plan.renderSize,
                renderScale: plan.renderScale,
                at: generatedSourceTime
            )
            let generatedRasterScale = generatedLayerRasterScale(
                for: plan,
                clip: clip,
                at: generatedSourceTime,
                textAnimationSample: sample,
                baseSize: baseGeometry.layerSize
            )
            let generatedScaleCorrection = CGSize(
                width: 1 / max(generatedRasterScale.width, 0.000_001),
                height: 1 / max(generatedRasterScale.height, 0.000_001)
            )
            rasterizationLock.lock()
            let result = textLayerRenderer.render(
                item: text,
                renderSize: plan.renderSize,
                renderScale: plan.renderScale,
                rasterScale: generatedRasterScale,
                at: generatedSourceTime,
                glyphReveal: sample.glyphReveal
            )
            let cacheKey = "text-\(ObjectIdentifier(result.image))" as NSString
            let image: CIImage
            do {
                image = try gpuCachedImageLocked(result.image, key: cacheKey)
            } catch {
                rasterizationLock.unlock()
                throw error
            }
            rasterizationLock.unlock()
            return SourceResult(
                image: image,
                textAnimationSample: sample,
                rasterScaleCorrection: generatedScaleCorrection
            )
        }
        if let stillImageURL = clip.stillImageURL {
            return SourceResult(
                image: try stillImage(at: stillImageURL),
                textAnimationSample: nil,
                rasterScaleCorrection: CGSize(width: 1, height: 1)
            )
        }
        guard clip.trackID != kCMPersistentTrackID_Invalid,
            let sourceBuffer = sourceFrame(clip.trackID)
        else {
            return SourceResult(
                image: nil,
                textAnimationSample: nil,
                rasterScaleCorrection: CGSize(width: 1, height: 1)
            )
        }

        var image = try frameResources.makeSourceImage(from: sourceBuffer)
            .transformed(by: clip.sourceTransform)
        if let settings = clip.backgroundRemoval {
            if let maskTrackID = clip.backgroundMaskTrackID,
                let maskBuffer = sourceFrame(maskTrackID)
            {
                let matte = try frameResources.makeSourceImage(from: maskBuffer)
                    .transformed(by: clip.backgroundMaskSourceTransform)
                image = applyBackgroundRemoval(
                    settings,
                    matte: matte,
                    to: image,
                    renderScale: plan.renderScale
                )
            } else {
                image = transparentImage(croppedTo: image.extent)
            }
        }
        return SourceResult(
            image: image,
            textAnimationSample: nil,
            rasterScaleCorrection: CGSize(width: 1, height: 1)
        )
    }

    private func generatedLayerSourceSampleTime(_ localTime: Double, plan: FrameRenderPlan) -> Double {
        guard plan.quality == .interactive else { return localTime }
        let step = max(plan.frameDuration * 3, 1 / 12)
        return quantize(localTime, step: step)
    }

    private func activeClips(in plan: FrameRenderPlan, at time: Double) -> [RenderClipDescriptor] {
        let active: [RenderClipDescriptor]
        if plan.clipIntervals.isEmpty {
            active = plan.clips.filter {
                $0.timelineStart <= time && $0.timelineStart + $0.duration > time
            }
        } else {
            var lower = 0
            var upper = plan.clipIntervals.count
            while lower < upper {
                let midpoint = (lower + upper) / 2
                if plan.clipIntervals[midpoint].end <= time {
                    lower = midpoint + 1
                } else {
                    upper = midpoint
                }
            }
            if plan.clipIntervals.indices.contains(lower) {
                let interval = plan.clipIntervals[lower]
                active = time >= interval.start && time < interval.end ? interval.clips : []
            } else {
                active = []
            }
        }

        var resolved = active
        let frameEnd = time + plan.frameDuration
        for clip in plan.clips where clip.text != nil
            && clip.timelineStart > time
            && clip.timelineStart < frameEnd
            && clip.timelineStart + clip.duration > time
            && !resolved.contains(where: { $0.clipID == clip.clipID })
        {
            resolved.append(clip)
        }
        return resolved
            .sorted { $0.renderOrder < $1.renderOrder }
            .map { $0.resolvingLiveOverride(from: plan.livePreviewState) }
    }

    private func stillImage(at url: URL) throws -> CIImage? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let gpuKey = stillImageCacheKey(for: url)
        if let cached = gpuImageCache.object(forKey: gpuKey) {
            os_signpost(.event, log: signpostLog, name: "Still Image Cache Hit")
            return cached.image
        }
        rasterizationLock.lock()
        defer { rasterizationLock.unlock() }
        if let cached = gpuImageCache.object(forKey: gpuKey) { return cached.image }
        let imageData = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let decoded = CIImage(
            data: imageData,
            options: [.applyOrientationProperty: true]
        ) else { return nil }
        return try gpuCachedImageLocked(decoded, key: gpuKey)
    }

    private func stillImageCacheKey(for url: URL) -> NSString {
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let values = try? freshURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ])
        let fileSize = values?.fileSize ?? -1
        let modifiedAt = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? -1
        let fileID = values?.fileResourceIdentifier.map { "\($0)" } ?? "unidentified"
        return "still-\(url.standardizedFileURL.path)-\(fileID)-\(fileSize)-\(modifiedAt)" as NSString
    }

    /// Uploads immutable text/still pixels once into the shared linear FP16
    /// working format. Subsequent frames reuse the GPU texture directly.
    /// Caller must hold `rasterizationLock`.
    private func gpuCachedImageLocked(_ source: CIImage, key: NSString) throws -> CIImage {
        if let cached = gpuImageCache.object(forKey: key) { return cached.image }
        let extent = source.extent.integral
        guard extent.width.isFinite, extent.height.isFinite,
            extent.width > 0, extent.height > 0
        else { throw MetalRenderingError.invalidRenderTarget }
        let width = max(Int(extent.width.rounded(.up)), 1)
        let height = max(Int(extent.height.rounded(.up)), 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = resources.device.makeTexture(descriptor: descriptor) else {
            throw MetalRenderingError.textureAllocationFailed(width: width, height: height)
        }
        texture.label = "Motionary cached immutable layer"
        guard let commandBuffer = resources.commandQueue.makeCommandBuffer() else {
            throw MetalRenderingError.commandBufferUnavailable
        }
        let localBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let transparentBase = transparentImage(croppedTo: localBounds)
        let local = source.transformed(by: CGAffineTransform(
            translationX: -extent.minX,
            y: -extent.minY
        ))
        .composited(over: transparentBase)
        .cropped(to: localBounds)
        resources.ciContext.render(
            local,
            to: texture,
            commandBuffer: commandBuffer,
            bounds: localBounds,
            colorSpace: resources.workingColorSpace
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed,
            let localImage = CIImage(
                mtlTexture: texture,
                options: [.colorSpace: resources.workingColorSpace]
            )
        else { throw MetalRenderingError.commandBufferFailed(commandBuffer.error) }
        let uprightLocalImage = localImage.transformed(
            by: CGAffineTransform(translationX: 0, y: CGFloat(height))
                .scaledBy(x: 1, y: -1)
        )
        let image = uprightLocalImage
            .transformed(by: CGAffineTransform(
                translationX: extent.minX,
                y: extent.minY
            ))
            .cropped(to: extent)
        gpuImageCache.setObject(
            CachedGPUImage(image: image, texture: texture),
            forKey: key,
            cost: max(width * height * 8, 1)
        )
        return image
    }

    private func shapeImage(
        _ shape: ClipShape,
        at time: Double,
        renderScale: CGFloat,
        rasterScale: CGSize
    ) throws -> CIImage {
        let layout = ShapeRasterLayout(
            shape: shape,
            at: time,
            logicalRenderScale: renderScale,
            rasterScale: rasterScale
        )
        let width = max(Int(layout.rasterSize.width.rounded(.up)), 1)
        let height = max(Int(layout.rasterSize.height.rounded(.up)), 1)
        let cacheKey = shapeCacheKey(shape: shape, layout: layout, at: time, renderScale: renderScale)
        if let cached = gpuImageCache.object(forKey: cacheKey) {
            return cached.image
        }

        rasterizationLock.lock()
        defer { rasterizationLock.unlock() }
        if let cached = gpuImageCache.object(forKey: cacheKey) {
            return cached.image
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = resources.device.makeTexture(descriptor: descriptor) else {
            throw MetalRenderingError.textureAllocationFailed(width: width, height: height)
        }
        texture.label = "Motionary cached shape layer"
        let pipeline = try resources.pipeline(named: "motionaryShapeKernel")
        guard let commandBuffer = resources.commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw MetalRenderingError.commandBufferUnavailable
        }
        let kind: UInt32
        switch shape.kind {
        case .rectangle: kind = 0
        case .roundedRectangle: kind = 1
        case .circle: kind = 2
        }
        encoder.label = "Metal shape source"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        var uniforms = MotionaryEffectUniforms(
            size: SIMD2(UInt32(width), UInt32(height)),
            effectKind: kind,
            seed: 0,
            time: Float(layout.logicalCornerRadius),
            frameIndex: 0,
            direction: SIMD2(Float(layout.rasterScale.width), Float(layout.rasterScale.height)),
            parameters: SIMD4(
                Float(shape.color.red),
                Float(shape.color.green),
                Float(shape.color.blue),
                Float(shape.color.alpha)
            )
        )
        guard let uniformsBuffer = resources.device.makeBuffer(
            bytes: &uniforms,
            length: MemoryLayout<MotionaryEffectUniforms>.stride,
            options: .storageModeShared
        ) else {
            throw MetalRenderingError.textureAllocationFailed(
                width: MemoryLayout<MotionaryEffectUniforms>.stride,
                height: 1
            )
        }
        encoder.setBuffer(uniformsBuffer, offset: 0, index: 0)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(pipeline.maxTotalThreadsPerThreadgroup / max(threadWidth, 1), 1)
        let threadsPerGroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let groups = MTLSize(
            width: (width + threadWidth - 1) / threadWidth,
            height: (height + threadHeight - 1) / threadHeight,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw MetalRenderingError.commandBufferFailed(commandBuffer.error)
        }
        guard let image = CIImage(
            mtlTexture: texture,
            options: [.colorSpace: self.resources.workingColorSpace]
        ) else { throw MetalRenderingError.invalidRenderTarget }
        gpuImageCache.setObject(
            CachedGPUImage(image: image, texture: texture),
            forKey: cacheKey,
            cost: max(width * height * 8, 1)
        )
        return image
    }

    private func shapeCacheKey(
        shape: ClipShape,
        layout: ShapeRasterLayout,
        at time: Double,
        renderScale: CGFloat
    ) -> NSString {
        [
            "shape",
            shape.kind.rawValue,
            String(format: "%.5f", shape.width.value(at: time)),
            String(format: "%.5f", shape.height.value(at: time)),
            String(format: "%.5f", shape.cornerRadius.value(at: time)),
            String(format: "%.5f", renderScale),
            String(format: "%.5f", layout.rasterScale.width),
            String(format: "%.5f", layout.rasterScale.height),
            "\(Int(layout.rasterSize.width.rounded()))",
            "\(Int(layout.rasterSize.height.rounded()))",
            String(format: "%.5f", layout.rasterCornerRadius),
            String(format: "%.5f", shape.color.red),
            String(format: "%.5f", shape.color.green),
            String(format: "%.5f", shape.color.blue),
            String(format: "%.5f", shape.color.alpha)
        ].joined(separator: "|") as NSString
    }

    private func quantize(_ value: Double, step: Double) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }

    private func place(
        _ image: CIImage,
        placementExtent: CGRect,
        clip: RenderClipDescriptor,
        at time: Double,
        renderSize: CGSize,
        isGeneratedLayer: Bool,
        rasterScaleCorrection: CGSize,
        textAnimationSample: TextAnimationSample?
    ) -> CIImage {
        guard placementExtent.width > 0, placementExtent.height > 0 else { return image }
        let fitScale = isGeneratedLayer
            ? 1
            : VideoSourceGeometry.fitScale(
                sourceSize: placementExtent.size,
                inside: renderSize
            ) ?? 1
        let scale = clip.transform.scale.value(at: time)
        let animationScale = textAnimationSample?.scale ?? 1
        let correctionX = isGeneratedLayer ? max(rasterScaleCorrection.width, 0.000_001) : 1
        let correctionY = isGeneratedLayer ? max(rasterScaleCorrection.height, 0.000_001) : 1
        let positiveScaleX = fitScale * correctionX * max(scale.x * animationScale, 0.001)
        let positiveScaleY = fitScale * correctionY * max(scale.y * animationScale, 0.001)
        let scaleX = clip.transform.isFlippedHorizontally ? -positiveScaleX : positiveScaleX
        let scaleY = clip.transform.isFlippedVertically ? -positiveScaleY : positiveScaleY
        let rotation = clip.transform.rotationDegrees.value(at: time) * .pi / 180
            + (textAnimationSample?.rotationRadians ?? 0)
        let animationTranslationScaleX = isGeneratedLayer ? correctionX : 1
        let animationTranslationScaleY = isGeneratedLayer ? correctionY : 1
        let positionX = clip.transform.positionX.value(at: time) * renderSize.width * 0.5
            + (textAnimationSample?.translationX ?? 0) * placementExtent.width * animationTranslationScaleX
        let positionY = -clip.transform.positionY.value(at: time) * renderSize.height * 0.5
            - (textAnimationSample?.translationY ?? 0) * placementExtent.height * animationTranslationScaleY

        return image
            .transformed(by: CGAffineTransform(
                translationX: -placementExtent.midX,
                y: -placementExtent.midY
            ))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(rotationAngle: rotation))
            .transformed(by: CGAffineTransform(
                translationX: renderSize.width * 0.5 + positionX,
                y: renderSize.height * 0.5 + positionY
            ))
    }

    private func projectedPlacementBounds(
        placementExtent: CGRect,
        clip: RenderClipDescriptor,
        at time: Double,
        renderSize: CGSize,
        isGeneratedLayer: Bool,
        rasterScaleCorrection: CGSize,
        textAnimationSample: TextAnimationSample?
    ) -> CGRect {
        guard placementExtent.width > 0, placementExtent.height > 0 else { return .null }
        let fitScale = isGeneratedLayer
            ? 1
            : VideoSourceGeometry.fitScale(
                sourceSize: placementExtent.size,
                inside: renderSize
            ) ?? 1
        let scale = clip.transform.scale.value(at: time)
        let animationScale = textAnimationSample?.scale ?? 1
        let correctionX = isGeneratedLayer ? max(rasterScaleCorrection.width, 0.000_001) : 1
        let correctionY = isGeneratedLayer ? max(rasterScaleCorrection.height, 0.000_001) : 1
        let scaleX = fitScale * correctionX * max(abs(scale.x) * animationScale, 0.001)
        let scaleY = fitScale * correctionY * max(abs(scale.y) * animationScale, 0.001)
        let rotation = clip.transform.rotationDegrees.value(at: time) * .pi / 180
            + (textAnimationSample?.rotationRadians ?? 0)
        let positionX = clip.transform.positionX.value(at: time) * renderSize.width * 0.5
            + (textAnimationSample?.translationX ?? 0) * placementExtent.width * correctionX
        let positionY = -clip.transform.positionY.value(at: time) * renderSize.height * 0.5
            - (textAnimationSample?.translationY ?? 0) * placementExtent.height * correctionY
        let center = CGPoint(
            x: renderSize.width * 0.5 + positionX,
            y: renderSize.height * 0.5 + positionY
        )
        let halfWidth = placementExtent.width * scaleX * 0.5
        let halfHeight = placementExtent.height * scaleY * 0.5
        let cosine = abs(cos(rotation))
        let sine = abs(sin(rotation))
        let rotatedHalfWidth = halfWidth * cosine + halfHeight * sine
        let rotatedHalfHeight = halfWidth * sine + halfHeight * cosine
        return CGRect(
            x: center.x - rotatedHalfWidth,
            y: center.y - rotatedHalfHeight,
            width: rotatedHalfWidth * 2,
            height: rotatedHalfHeight * 2
        )
    }

    private func applyClipReveal(_ progress: Double, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let progress = min(max(progress, 0), 1)
        guard progress < 0.999_999 else { return image }
        guard progress > 0.000_001 else { return transparentImage(croppedTo: extent) }
        let visibleRect = CGRect(
            x: extent.minX,
            y: extent.minY,
            width: extent.width * progress,
            height: extent.height
        )
        return image
            .cropped(to: visibleRect)
            .composited(over: transparentImage(croppedTo: extent))
            .cropped(to: extent)
    }

    private func applyMask(_ mask: ItemMask?, to image: CIImage) -> CIImage {
        guard let mask else { return image }
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        let maskSize = CGSize(
            width: extent.width * CGFloat(max(mask.widthScale, 0)),
            height: extent.height * CGFloat(max(mask.heightScale, 0))
        )
        guard maskSize.width > 0.5, maskSize.height > 0.5 else {
            return mask.isInverted ? image : transparentImage(croppedTo: extent)
        }
        let maskRect = CGRect(
            x: extent.midX - maskSize.width * 0.5,
            y: extent.midY - maskSize.height * 0.5,
            width: maskSize.width,
            height: maskSize.height
        )
        let featherRadius = CGFloat(max(mask.featherScale, 0)) * max(extent.width, extent.height)
        let cacheKey = NSString(
            format: "%@-%.2f-%.2f-%.2f-%.2f-%.4f-%.4f-%.4f-%.4f-%.2f-%.4f-%d",
            mask.shape.rawValue, extent.minX, extent.minY, extent.width, extent.height,
            mask.widthScale, mask.heightScale, mask.featherScale, mask.roundnessScale,
            mask.rotationDegrees, mask.offsetScale, mask.isInverted ? 1 : 0
        )
        if let cached = maskImageCache.object(forKey: cacheKey) {
            return blend(image, with: cached, in: extent)
        }

        rasterizationLock.lock()
        var maskImage = rasterMask(mask: mask, maskRect: maskRect, extent: extent)
        rasterizationLock.unlock()
        if featherRadius > 0.5 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = maskImage.clampedToExtent()
            blur.radius = Float(featherRadius)
            maskImage = (blur.outputImage ?? maskImage).cropped(to: extent)
        } else {
            maskImage = maskImage.cropped(to: extent)
        }
        maskImageCache.setObject(maskImage, forKey: cacheKey, cost: Int(extent.width * extent.height))
        return blend(image, with: maskImage, in: extent)
    }

    private func blend(_ image: CIImage, with maskImage: CIImage, in extent: CGRect) -> CIImage {
        let filter = CIFilter.blendWithMask()
        filter.inputImage = image
        filter.backgroundImage = transparentImage(croppedTo: extent)
        filter.maskImage = maskImage
        return (filter.outputImage ?? image).cropped(to: extent)
    }

    private func applyBackgroundRemoval(
        _ settings: BackgroundRemovalSettings,
        matte: CIImage,
        to image: CIImage,
        renderScale: CGFloat
    ) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1,
            matte.extent.width > 1, matte.extent.height > 1
        else { return transparentImage(croppedTo: extent) }
        let normalizedMatte = matte.transformed(
            by: CGAffineTransform(translationX: -matte.extent.minX, y: -matte.extent.minY)
        )
        var alignedMatte = normalizedMatte
            .transformed(by: CGAffineTransform(
                scaleX: extent.width / normalizedMatte.extent.width,
                y: extent.height / normalizedMatte.extent.height
            ))
            .transformed(by: CGAffineTransform(
                translationX: extent.minX,
                y: extent.minY
            ))
            .cropped(to: extent)

        let edgeRadius = Float(abs(settings.edgeRefinement) * 12 * Double(renderScale))
        if edgeRadius > 0.05 {
            if settings.edgeRefinement > 0 {
                let morphology = CIFilter.morphologyMaximum()
                morphology.inputImage = alignedMatte.clampedToExtent()
                morphology.radius = edgeRadius
                alignedMatte = (morphology.outputImage ?? alignedMatte).cropped(to: extent)
            } else {
                let morphology = CIFilter.morphologyMinimum()
                morphology.inputImage = alignedMatte.clampedToExtent()
                morphology.radius = edgeRadius
                alignedMatte = (morphology.outputImage ?? alignedMatte).cropped(to: extent)
            }
        }
        let featherRadius = Float(settings.feather * 24 * Double(renderScale))
        if featherRadius > 0.05 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = alignedMatte.clampedToExtent()
            blur.radius = featherRadius
            alignedMatte = (blur.outputImage ?? alignedMatte).cropped(to: extent)
        }
        let alphaBlend = CIFilter.blendWithAlphaMask()
        alphaBlend.inputImage = image
        alphaBlend.backgroundImage = transparentImage(croppedTo: extent)
        alphaBlend.maskImage = alignedMatte
        return (alphaBlend.outputImage ?? image).cropped(to: extent)
    }

    private func rasterMask(mask: ItemMask, maskRect: CGRect, extent: CGRect) -> CIImage {
        let size = CGSize(width: ceil(extent.width), height: ceil(extent.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let raster = UIGraphicsImageRenderer(size: size, format: format).image { context in
            (mask.isInverted ? UIColor.white : UIColor.black).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            context.cgContext.translateBy(x: center.x, y: center.y)
            context.cgContext.rotate(by: CGFloat(mask.rotationDegrees) * .pi / 180)
            context.cgContext.translateBy(x: -center.x, y: -center.y)
            let offset = CGFloat(mask.offsetScale) * extent.height * 0.5
            let rect = maskRect
                .offsetBy(dx: -extent.minX, dy: -extent.minY)
                .offsetBy(dx: 0, dy: offset)
            let roundness = CGFloat(mask.roundnessScale)
            let color = mask.isInverted ? UIColor.black : UIColor.white
            let path: UIBezierPath?
            switch mask.shape {
            case .rectangle, .roundedRectangle:
                path = UIBezierPath(
                    roundedRect: rect,
                    cornerRadius: min(rect.width, rect.height) * roundness * 0.5
                )
            case .ellipse:
                path = UIBezierPath(ovalIn: rect)
            case .diamond:
                path = roundedPolygonPath([
                    CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
                    CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)
                ], radius: min(rect.width, rect.height) * roundness * 0.16)
            case .triangle:
                path = roundedPolygonPath([
                    CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
                    CGPoint(x: rect.minX, y: rect.maxY)
                ], radius: min(rect.width, rect.height) * roundness * 0.12)
            case .star:
                path = starPath(in: rect, roundness: roundness)
            case .heart:
                path = nil
                let heart = mask.isInverted ? heartMaskSymbols.inverted : heartMaskSymbols.normal
                heart?.draw(in: rect)
            case .bar:
                let length = hypot(size.width, size.height) * 3
                path = UIBezierPath(
                    roundedRect: CGRect(
                        x: center.x - length * 0.5,
                        y: rect.midY - rect.height * 0.5,
                        width: length,
                        height: rect.height
                    ),
                    cornerRadius: rect.height * roundness * 0.5
                )
            case .split:
                let length = hypot(size.width, size.height) * 3
                path = UIBezierPath(rect: CGRect(
                    x: center.x - length * 0.5,
                    y: center.y + offset,
                    width: length,
                    height: length
                ))
            }
            color.setFill()
            path?.fill()
        }
        guard let cgImage = raster.cgImage else {
            return CIImage(color: .black).cropped(to: extent)
        }
        return CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    private func polygonPath(_ points: [CGPoint]) -> UIBezierPath {
        let path = UIBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        path.close()
        return path
    }

    private func roundedPolygonPath(_ points: [CGPoint], radius: CGFloat) -> UIBezierPath {
        guard points.count > 2, radius > 0.5 else { return polygonPath(points) }
        let shortestEdge = points.indices.reduce(CGFloat.greatestFiniteMagnitude) { result, index in
            let point = points[index]
            let next = points[(index + 1) % points.count]
            return min(result, hypot(next.x - point.x, next.y - point.y))
        }
        let path = CGMutablePath()
        path.move(to: points.last!)
        for index in points.indices {
            path.addArc(
                tangent1End: points[index],
                tangent2End: points[(index + 1) % points.count],
                radius: min(radius, shortestEdge * 0.22)
            )
        }
        path.closeSubpath()
        return UIBezierPath(cgPath: path)
    }

    private func starPath(in rect: CGRect, roundness: CGFloat) -> UIBezierPath {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) * 0.5
        let innerRadius = outerRadius * 0.43
        let points = (0..<10).map { index in
            let radius = index.isMultiple(of: 2) ? outerRadius : innerRadius
            let angle = -.pi / 2 + CGFloat(index) * .pi / 5
            return CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
        }
        return roundedPolygonPath(
            points,
            radius: min(rect.width, rect.height) * roundness * 0.045
        )
    }

    private func applyAdjustments(
        _ adjustments: AdjustmentSettings,
        to image: CIImage,
        at time: Double
    ) -> CIImage {
        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = image
        colorControls.brightness = Float(adjustments.brightness.value(at: time))
        colorControls.contrast = Float(adjustments.contrast.value(at: time))
        colorControls.saturation = Float(adjustments.saturation.value(at: time))
        var output = colorControls.outputImage ?? image
        let exposure = adjustments.exposure.value(at: time)
        if abs(exposure) > 0.001 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            filter.ev = Float(exposure)
            output = filter.outputImage ?? output
        }
        return output
    }

    private func applyOpacity(_ opacity: Double, to image: CIImage) -> CIImage {
        guard opacity < 0.999 else { return image }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        return filter.outputImage ?? image
    }

    private func transparentImage(croppedTo extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: extent)
    }

    private func attachRec709Metadata(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
    }

    private func measured<T>(
        _ name: StaticString,
        id: OSSignpostID,
        operation: () throws -> T
    ) rethrows -> T {
        os_signpost(.begin, log: signpostLog, name: name, signpostID: id)
        defer { os_signpost(.end, log: signpostLog, name: name, signpostID: id) }
        return try operation()
    }
}
