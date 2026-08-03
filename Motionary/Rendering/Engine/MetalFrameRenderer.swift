@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Metal
import os
import UIKit

enum ShapeRasterizationPolicy {
    static func requiresFrameLocalEncoding(
        shape: ClipShape,
        transform: ClipTransform,
        hasTransientScaleOverride: Bool
    ) -> Bool {
        shape.hasAnimatedRasterProperties
            || !transform.scale.keyframes.isEmpty
            || hasTransientScaleOverride
    }
}

enum GeneratedLayerSamplingPolicy {
    /// Interactive text rasterization is capped at 30 distinct samples per
    /// second on higher-frame-rate projects. It never drops below the native
    /// project cadence for 30 fps and slower timelines, avoiding the visibly
    /// stepped 12 fps animation cadence of the previous policy.
    static func sourceTime(
        _ localTime: Double,
        frameDuration: Double,
        quality: RenderQualityProfile
    ) -> Double {
        guard quality == .interactive else { return localTime }
        let safeTime = localTime.isFinite ? max(localTime, 0) : 0
        let safeFrameDuration =
            frameDuration.isFinite && frameDuration > 0
            ? frameDuration
            : 1 / 30
        let step = max(safeFrameDuration, 1 / 30)
        return ((safeTime / step) + 1e-9).rounded(.down) * step
    }
}

struct TextFramePreparationMetrics: Equatable {
    let itemResolutions: Int
    let layoutKeyCreations: Int
    let layoutPreparations: Int
    let rasterKeyCreations: Int
    let inFrameTextureUploads: Int
    let standaloneTextureUploadSubmissions: Int
}

/// Owns the complete GPU frame graph. The AVFoundation compositor only adapts
/// asynchronous requests into this synchronous, bounded render operation.
final class MetalFrameRenderer: @unchecked Sendable {
    typealias SourceFrameProvider = (CMPersistentTrackID) -> CVPixelBuffer?

    private let resources: MetalRenderResources
    private let effectRegistry: EffectRenderRegistry
    private let textLayerRenderer = TextLayerRenderer()
    private let rasterizationLock = NSLock()
    private var gpuImageCacheGeneration: UInt64 = 0
    private var inFrameTextTextureUploadCount = 0
    private var standaloneTextureUploadSubmissionCount = 0
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
            isCancelled: isCancelled,
            usesResponsiveFrameAcquire: false
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
                isCancelled: isCancelled,
                usesResponsiveFrameAcquire: true
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
        isCancelled: () -> Bool,
        usesResponsiveFrameAcquire: Bool
    ) throws -> MetalFrameResources {
        guard !isCancelled() else { throw MetalRenderingError.cancelled }
        let frameResources = try usesResponsiveFrameAcquire
            ? resources.beginFrame(isCancelled: isCancelled)
            : resources.beginFrame()
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
                if clip.isAdjustmentLayer {
                    output = try measured("Adjustment Layer", id: signpostID) {
                        try applyAdjustmentLayer(
                            clip,
                            to: output,
                            canvasRect: canvasRect,
                            at: localTime,
                            compositionTime: safeTime,
                            frameIndex: frameIndex,
                            plan: plan,
                            resources: frameResources
                        )
                    }
                    continue
                }
                let isGeneratedLayer = clip.shape != nil || clip.text != nil
                let generatedPreparation = prepareGeneratedLayer(
                    for: clip,
                    at: localTime,
                    plan: plan
                )
                let cullingMargin = max(plan.renderSize.width, plan.renderSize.height) * 0.25
                if isGeneratedLayer,
                    let estimatedBounds = estimatedGeneratedPlacementBounds(
                        for: clip,
                        at: localTime,
                        plan: plan,
                        preparation: generatedPreparation
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
                        generatedPreparation: generatedPreparation,
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
        gpuImageCacheGeneration &+= 1
        maskImageCache.removeAllObjects()
        gpuImageCache.removeAllObjects()
        textLayerRenderer.removeAllObjects()
        rasterizationLock.unlock()
        resources.purgeCaches()
    }

    func textPreparationMetrics() -> TextFramePreparationMetrics {
        rasterizationLock.lock()
        defer { rasterizationLock.unlock() }
        return TextFramePreparationMetrics(
            itemResolutions: textLayerRenderer.itemResolutionCount,
            layoutKeyCreations: textLayerRenderer.layoutKeyCreationCount,
            layoutPreparations: textLayerRenderer.layoutPreparationCount,
            rasterKeyCreations: textLayerRenderer.rasterKeyCreationCount,
            inFrameTextureUploads: inFrameTextTextureUploadCount,
            standaloneTextureUploadSubmissions: standaloneTextureUploadSubmissionCount
        )
    }

    /// A render-size transition invalidates reusable scratch and Core Video
    /// wrappers, while content-addressed shape/text/still/mask entries remain
    /// valid and are naturally bounded by their individual NSCache budgets.
    func renderContextDidChange() {
        resources.purgeTransientResources()
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

    private struct GeneratedLayerPreparation {
        let sourceTime: Double
        let textAnimationSample: TextAnimationSample?
        let textSample: TextLayerRenderer.PreparedSample?
    }

    private func prepareGeneratedLayer(
        for clip: RenderClipDescriptor,
        at localTime: Double,
        plan: FrameRenderPlan
    ) -> GeneratedLayerPreparation? {
        if clip.shape != nil {
            return GeneratedLayerPreparation(
                sourceTime: localTime,
                textAnimationSample: nil,
                textSample: nil
            )
        }
        guard let text = clip.text else { return nil }
        let sourceTime = generatedLayerSourceSampleTime(localTime, plan: plan)
        let animationSample = TextAnimationEvaluator.sample(
            animations: text.animations,
            at: sourceTime,
            clipDuration: text.duration
        )
        rasterizationLock.lock()
        defer { rasterizationLock.unlock() }
        let textSample = textLayerRenderer.prepareSample(
            item: text,
            renderSize: plan.renderSize,
            renderScale: plan.renderScale,
            at: sourceTime,
            glyphReveal: animationSample.glyphReveal
        )
        return GeneratedLayerPreparation(
            sourceTime: sourceTime,
            textAnimationSample: animationSample,
            textSample: textSample
        )
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
        plan: FrameRenderPlan,
        preparation: GeneratedLayerPreparation?
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

        if clip.text != nil,
            let sample = preparation?.textAnimationSample,
            let geometry = preparation?.textSample?.geometry
        {
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
        generatedPreparation: GeneratedLayerPreparation?,
        sourceFrame: SourceFrameProvider,
        resources frameResources: MetalFrameResources
    ) throws -> SourceResult {
        // Shape geometry is a cheap Metal kernel and must follow keyframes at
        // the actual frame time. Text rasterization remains quantized only in
        // interactive quality because glyph layout is substantially heavier.
        let generatedSourceTime = generatedPreparation?.sourceTime ?? localTime
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
            let shouldEncodeInCurrentFrame =
                ShapeRasterizationPolicy.requiresFrameLocalEncoding(
                    shape: shape,
                    transform: clip.transform,
                    hasTransientScaleOverride: clip.hasTransientRasterScaleOverride
                )
            let sourceImage: CIImage
            if shouldEncodeInCurrentFrame {
                sourceImage = try frameShapeImage(
                    shape,
                    at: generatedSourceTime,
                    renderScale: plan.renderScale,
                    rasterScale: generatedRasterScale,
                    resources: frameResources
                )
            } else {
                sourceImage = try shapeImage(
                    shape,
                    at: generatedSourceTime,
                    renderScale: plan.renderScale,
                    rasterScale: generatedRasterScale,
                    resources: frameResources
                )
            }
            return SourceResult(
                image: sourceImage,
                textAnimationSample: nil,
                rasterScaleCorrection: generatedScaleCorrection
            )
        }
        if clip.text != nil {
            guard let sample = generatedPreparation?.textAnimationSample,
                let preparedText = generatedPreparation?.textSample
            else {
                return SourceResult(
                    image: nil,
                    textAnimationSample: nil,
                    rasterScaleCorrection: CGSize(width: 1, height: 1)
                )
            }
            rasterizationLock.lock()
            defer { rasterizationLock.unlock() }
            let generatedRasterScale = generatedLayerRasterScale(
                for: plan,
                clip: clip,
                at: generatedSourceTime,
                textAnimationSample: sample,
                baseSize: preparedText.geometry.layerSize
            )
            let generatedScaleCorrection = CGSize(
                width: 1 / max(generatedRasterScale.width, 0.000_001),
                height: 1 / max(generatedRasterScale.height, 0.000_001)
            )
            let result = textLayerRenderer.render(
                preparedText,
                rasterScale: generatedRasterScale
            )
            let cacheKey = "text-\(result.cacheIdentity.uuidString)" as NSString
            let image = try frameCachedTextImageLocked(
                result.image,
                key: cacheKey,
                resources: frameResources
            )
            return SourceResult(
                image: image,
                textAnimationSample: sample,
                rasterScaleCorrection: generatedScaleCorrection
            )
        }
        if let stillImageURL = clip.stillImageURL {
            return SourceResult(
                image: try stillImage(
                    at: stillImageURL,
                    cacheIdentity: clip.stillImageCacheIdentity,
                    resources: frameResources
                ),
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

    private func applyAdjustmentLayer(
        _ clip: RenderClipDescriptor,
        to background: CIImage,
        canvasRect: CGRect,
        at localTime: Double,
        compositionTime: Double,
        frameIndex: Int64,
        plan: FrameRenderPlan,
        resources frameResources: MetalFrameResources
    ) throws -> CIImage {
        if adjustmentLayerIsNoOp(clip, at: localTime) {
            return background
        }
        let opacity = min(max(clip.transform.opacity.value(at: localTime), 0), 1)
        guard opacity > 0.000_001 else { return background }
        let source = background.cropped(to: canvasRect)
        let adjusted = applyAdjustments(clip.adjustments, to: source, at: localTime)
        var processed = try effectRegistry.render(
            clip.effectStack,
            to: adjusted,
            context: EffectRenderContext(
                compositionTime: compositionTime,
                clipTime: localTime,
                frameIndex: frameIndex,
                itemID: clip.clipID,
                renderScale: plan.renderScale,
                quality: plan.quality
            ),
            resources: frameResources,
            failurePolicy: plan.failurePolicy
        )
        .cropped(to: canvasRect)
        if clip.blendMode != .normal && clip.blendIntensity > 0.000_001 {
            processed = try MetalLayerCompositor.blend(
                foreground: processed,
                background: source,
                in: canvasRect,
                mode: clip.blendMode,
                intensity: clip.blendIntensity,
                resources: frameResources
            )
        }
        let effectMask = adjustmentLayerMask(
            clip,
            canvasRect: canvasRect,
            at: localTime,
            renderSize: plan.renderSize,
            opacity: opacity
        )
        return blend(processed, over: source, alphaMask: effectMask, in: canvasRect)
    }

    private func adjustmentLayerMask(
        _ clip: RenderClipDescriptor,
        canvasRect: CGRect,
        at localTime: Double,
        renderSize: CGSize,
        opacity: Double
    ) -> CIImage {
        var mask = CIImage(color: CIColor(red: opacity, green: opacity, blue: opacity, alpha: opacity))
            .cropped(to: canvasRect)
        mask = applyMask(clip.mask, to: mask)
        mask = place(
            mask,
            placementExtent: canvasRect,
            clip: clip,
            at: localTime,
            renderSize: renderSize,
            isGeneratedLayer: false,
            rasterScaleCorrection: CGSize(width: 1, height: 1),
            textAnimationSample: nil
        )
        return mask
            .composited(over: transparentImage(croppedTo: canvasRect))
            .cropped(to: canvasRect)
    }

    private func adjustmentLayerIsNoOp(
        _ clip: RenderClipDescriptor,
        at time: Double
    ) -> Bool {
        guard clip.mask == nil,
            !clip.effectStack.effects.contains(where: \.isEnabled),
            clip.blendMode == .normal || clip.blendIntensity <= 0.000_001,
            !clip.transform.isFlippedHorizontally,
            !clip.transform.isFlippedVertically
        else { return false }

        let scale = clip.transform.scale.value(at: time)
        let rotation = clip.transform.rotationDegrees.value(at: time)
            .truncatingRemainder(dividingBy: 360)
        let adjustments = clip.adjustments
        return abs(clip.transform.positionX.value(at: time)) <= 0.000_001
            && abs(clip.transform.positionY.value(at: time)) <= 0.000_001
            && abs(scale.x - 1) <= 0.000_001
            && abs(scale.y - 1) <= 0.000_001
            && abs(rotation) <= 0.000_001
            && clip.transform.opacity.value(at: time) >= 0.999_999
            && abs(adjustments.brightness.value(at: time)) <= 0.000_001
            && abs(adjustments.contrast.value(at: time) - 1) <= 0.000_001
            && abs(adjustments.saturation.value(at: time) - 1) <= 0.000_001
            && abs(adjustments.exposure.value(at: time)) <= 0.000_001
    }

    private func generatedLayerSourceSampleTime(_ localTime: Double, plan: FrameRenderPlan) -> Double {
        GeneratedLayerSamplingPolicy.sourceTime(
            localTime,
            frameDuration: plan.frameDuration,
            quality: plan.quality
        )
    }

    private func activeClips(in plan: FrameRenderPlan, at time: Double) -> [RenderClipDescriptor] {
        let active: [RenderClipDescriptor]
        var requiresOrdering = false
        if plan.clipIntervals.isEmpty {
            active = plan.clips.filter {
                $0.timelineStart <= time && $0.timelineStart + $0.duration > time
            }
            requiresOrdering = true
        } else {
            active = plan.clipIntervals.activeClipIndices(at: time).map { plan.clips[$0] }
        }

        var resolved = active
        let frameEnd = time + plan.frameDuration
        var textIndex = firstTextClipIndex(after: time, in: plan.textClipsByStart)
        while textIndex < plan.textClipsByStart.count {
            let clip = plan.textClipsByStart[textIndex]
            guard clip.timelineStart < frameEnd else { break }
            if clip.timelineStart + clip.duration > time,
                !resolved.contains(where: { $0.clipID == clip.clipID })
            {
                resolved.append(clip)
                requiresOrdering = true
            }
            textIndex += 1
        }
        if requiresOrdering {
            resolved.sort { $0.renderOrder < $1.renderOrder }
        }
        guard let livePreviewSnapshot = plan.livePreviewSnapshot,
            !livePreviewSnapshot.overrides.isEmpty
        else {
            return resolved
        }
        return resolved.map { $0.resolvingLiveOverride(from: livePreviewSnapshot) }
    }

    private func firstTextClipIndex(
        after time: Double,
        in textClipsByStart: [RenderClipDescriptor]
    ) -> Int {
        var lower = 0
        var upper = textClipsByStart.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if textClipsByStart[midpoint].timelineStart <= time {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        return lower
    }

    private func stillImage(
        at url: URL,
        cacheIdentity: String?,
        resources frameResources: MetalFrameResources? = nil
    ) throws -> CIImage? {
        // Composition compilation performs file validation and identity
        // resolution once. Cache hits in this frame path must not touch the
        // filesystem or security-scoped resource machinery.
        let gpuKey = "still-\(cacheIdentity ?? url.standardizedFileURL.path)" as NSString
        if let cached = gpuImageCache.object(forKey: gpuKey) {
            os_signpost(.event, log: signpostLog, name: "Still Image Cache Hit")
            return cached.image
        }
        rasterizationLock.lock()
        defer { rasterizationLock.unlock() }
        if let cached = gpuImageCache.object(forKey: gpuKey) { return cached.image }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let imageData = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let decoded = CIImage(
            data: imageData,
            options: [.applyOrientationProperty: true]
        ) else { return nil }
        if let frameResources {
            return try frameCachedImageLocked(
                decoded,
                key: gpuKey,
                resources: frameResources,
                textureLabel: "Motionary in-frame cached still layer",
                signpostName: "Still Texture Upload Encoded"
            )
        }
        return try gpuCachedImageLocked(decoded, key: gpuKey)
    }

    /// Uploads immutable still/static generated pixels once into the shared
    /// linear FP16 working format. Frame-hot text misses use the nonblocking
    /// in-frame path below.
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
        standaloneTextureUploadSubmissionCount &+= 1
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

    /// Encodes a text cache miss into the frame that will consume it. The
    /// resulting image is frame-local until that command buffer completes, so
    /// concurrent frames can never observe a texture before its upload has
    /// executed. Successful uploads are published to the shared cache from the
    /// frame completion hook; abandoned or failed frames publish nothing.
    /// Caller must hold `rasterizationLock`.
    private func frameCachedTextImageLocked(
        _ source: CIImage,
        key: NSString,
        resources frameResources: MetalFrameResources
    ) throws -> CIImage {
        try frameCachedImageLocked(
            source,
            key: key,
            resources: frameResources,
            textureLabel: "Motionary in-frame cached text layer",
            signpostName: "Text Texture Upload Encoded",
            incrementTextUploadMetric: true
        )
    }

    /// Encodes immutable/generated pixels into the current frame's command
    /// buffer. This keeps AVFoundation's asynchronous compositor path free from
    /// nested GPU submissions and blocking waits on cache misses.
    /// Caller must hold `rasterizationLock`.
    private func frameCachedImageLocked(
        _ source: CIImage,
        key: NSString,
        resources frameResources: MetalFrameResources,
        textureLabel: String,
        signpostName: StaticString,
        incrementTextUploadMetric: Bool = false
    ) throws -> CIImage {
        if let cached = gpuImageCache.object(forKey: key) {
            os_signpost(.event, log: signpostLog, name: "Text Texture Cache Hit")
            return cached.image
        }
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
        descriptor.hazardTrackingMode = .tracked
        guard let texture = resources.device.makeTexture(descriptor: descriptor) else {
            throw MetalRenderingError.textureAllocationFailed(width: width, height: height)
        }
        texture.label = textureLabel
        let localBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let transparentBase = transparentImage(croppedTo: localBounds)
        let local = source.transformed(by: CGAffineTransform(
            translationX: -extent.minX,
            y: -extent.minY
        ))
        .composited(over: transparentBase)
        .cropped(to: localBounds)
        self.resources.ciContext.render(
            local,
            to: texture,
            commandBuffer: frameResources.commandBuffer,
            bounds: localBounds,
            colorSpace: self.resources.workingColorSpace
        )
        guard let localImage = CIImage(
            mtlTexture: texture,
            options: [.colorSpace: resources.workingColorSpace]
        ) else { throw MetalRenderingError.invalidRenderTarget }
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
        let cachedImage = CachedGPUImage(image: image, texture: texture)
        let generation = gpuImageCacheGeneration
        frameResources.addCompletionHandler { [weak self, cachedImage] commandBuffer in
            guard commandBuffer.status == .completed, let self else { return }
            self.rasterizationLock.lock()
            defer { self.rasterizationLock.unlock() }
            guard self.gpuImageCacheGeneration == generation else { return }
            if self.gpuImageCache.object(forKey: key) == nil {
                self.gpuImageCache.setObject(
                    cachedImage,
                    forKey: key,
                    cost: max(width * height * 8, 1)
                )
            }
        }
        if incrementTextUploadMetric {
            inFrameTextTextureUploadCount &+= 1
        }
        os_signpost(
            .event,
            log: signpostLog,
            name: signpostName,
            "%d x %d",
            width,
            height
        )
        return image
    }

    private func shapeImage(
        _ shape: ClipShape,
        at time: Double,
        renderScale: CGFloat,
        rasterScale: CGSize,
        resources frameResources: MetalFrameResources? = nil
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

        if let frameResources {
            return try frameCachedShapeImageLocked(
                shape,
                layout: layout,
                width: width,
                height: height,
                cacheKey: cacheKey,
                resources: frameResources
            )
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

    /// Encodes a static shape cache miss into the frame that consumes it. This
    /// removes the blocking standalone command-buffer wait from preview playback.
    /// Caller must hold `rasterizationLock`.
    private func frameCachedShapeImageLocked(
        _ shape: ClipShape,
        layout: ShapeRasterLayout,
        width: Int,
        height: Int,
        cacheKey: NSString,
        resources frameResources: MetalFrameResources
    ) throws -> CIImage {
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
        descriptor.hazardTrackingMode = .tracked
        guard let texture = resources.device.makeTexture(descriptor: descriptor) else {
            throw MetalRenderingError.textureAllocationFailed(width: width, height: height)
        }
        texture.label = "Motionary in-frame cached shape layer"
        let pipeline = try resources.pipeline(named: "motionaryShapeKernel")
        guard let encoder = frameResources.commandBuffer.makeComputeCommandEncoder() else {
            throw MetalRenderingError.commandBufferUnavailable
        }
        let kind: UInt32
        switch shape.kind {
        case .rectangle: kind = 0
        case .roundedRectangle: kind = 1
        case .circle: kind = 2
        }
        encoder.label = "Metal static shape source"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        let uniforms = try frameResources.writeUniforms(MotionaryEffectUniforms(
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
        ))
        encoder.setBuffer(uniforms.buffer, offset: uniforms.offset, index: 0)
        frameResources.dispatch(
            encoder: encoder,
            pipeline: pipeline,
            width: width,
            height: height
        )
        encoder.endEncoding()
        guard let image = CIImage(
            mtlTexture: texture,
            options: [.colorSpace: self.resources.workingColorSpace]
        ) else { throw MetalRenderingError.invalidRenderTarget }
        let cachedImage = CachedGPUImage(image: image, texture: texture)
        let generation = gpuImageCacheGeneration
        frameResources.addCompletionHandler { [weak self, cachedImage] commandBuffer in
            guard commandBuffer.status == .completed, let self else { return }
            self.rasterizationLock.lock()
            defer { self.rasterizationLock.unlock() }
            guard self.gpuImageCacheGeneration == generation else { return }
            if self.gpuImageCache.object(forKey: cacheKey) == nil {
                self.gpuImageCache.setObject(
                    cachedImage,
                    forKey: cacheKey,
                    cost: max(width * height * 8, 1)
                )
            }
        }
        return image
    }

    /// Encodes time-varying shape pixels into the frame's existing command
    /// buffer. This avoids creating and synchronously waiting for a separate
    /// GPU submission on every animated geometry/scale sample.
    private func frameShapeImage(
        _ shape: ClipShape,
        at time: Double,
        renderScale: CGFloat,
        rasterScale: CGSize,
        resources frameResources: MetalFrameResources
    ) throws -> CIImage {
        let layout = ShapeRasterLayout(
            shape: shape,
            at: time,
            logicalRenderScale: renderScale,
            rasterScale: rasterScale
        )
        let width = max(Int(layout.rasterSize.width.rounded(.up)), 1)
        let height = max(Int(layout.rasterSize.height.rounded(.up)), 1)
        let texture = try frameResources.makeScratchTexture(width: width, height: height)
        texture.label = "Motionary frame-local animated shape"
        let pipeline = try resources.pipeline(named: "motionaryShapeKernel")
        guard let encoder = frameResources.commandBuffer.makeComputeCommandEncoder() else {
            throw MetalRenderingError.commandBufferUnavailable
        }
        let kind: UInt32
        switch shape.kind {
        case .rectangle: kind = 0
        case .roundedRectangle: kind = 1
        case .circle: kind = 2
        }
        encoder.label = "Metal animated shape source"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        let uniforms = try frameResources.writeUniforms(MotionaryEffectUniforms(
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
        ))
        encoder.setBuffer(uniforms.buffer, offset: uniforms.offset, index: 0)
        frameResources.dispatch(
            encoder: encoder,
            pipeline: pipeline,
            width: width,
            height: height
        )
        encoder.endEncoding()
        guard let image = CIImage(
            mtlTexture: texture,
            options: [.colorSpace: resources.workingColorSpace]
        ) else {
            throw MetalRenderingError.invalidRenderTarget
        }
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
        defer { rasterizationLock.unlock() }
        if let cached = maskImageCache.object(forKey: cacheKey) {
            return blend(image, with: cached, in: extent)
        }
        var maskImage = rasterMask(mask: mask, maskRect: maskRect, extent: extent)
        if featherRadius > 0.5 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = maskImage.clampedToExtent()
            blur.radius = Float(featherRadius)
            maskImage = (blur.outputImage ?? maskImage).cropped(to: extent)
        } else {
            maskImage = maskImage.cropped(to: extent)
        }
        let byteCost = Int(
            min(
                extent.width * extent.height * 4,
                CGFloat(Int.max)
            )
        )
        maskImageCache.setObject(maskImage, forKey: cacheKey, cost: max(byteCost, 1))
        return blend(image, with: maskImage, in: extent)
    }

    private func blend(_ image: CIImage, with maskImage: CIImage, in extent: CGRect) -> CIImage {
        let filter = CIFilter.blendWithMask()
        filter.inputImage = image
        filter.backgroundImage = transparentImage(croppedTo: extent)
        filter.maskImage = maskImage
        return (filter.outputImage ?? image).cropped(to: extent)
    }

    private func blend(
        _ image: CIImage,
        over background: CIImage,
        alphaMask maskImage: CIImage,
        in extent: CGRect
    ) -> CIImage {
        let filter = CIFilter.blendWithAlphaMask()
        filter.inputImage = image
        filter.backgroundImage = background
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

extension ClipShape {
    var hasAnimatedRasterProperties: Bool {
        !width.keyframes.isEmpty
            || !height.keyframes.isEmpty
            || !cornerRadius.keyframes.isEmpty
    }
}
