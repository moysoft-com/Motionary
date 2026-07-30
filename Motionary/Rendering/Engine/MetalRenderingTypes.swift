@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Metal
import os
import simd

enum RenderQualityProfile: String, Sendable {
    case interactive
    case balanced
    case export

    var blurScale: Float {
        switch self {
        case .interactive, .balanced: 1
        case .export: 1
        }
    }
}

enum GeneratedRasterPolicy {
    static let maximumTextureDimension = 8_192
    static let interactiveMaximumTextureDimension = 1_536
    static let maximumRasterizedCanvasCoverage: CGFloat = 10
    static let textCacheBytes = 64 * 1_024 * 1_024
    static let gpuImageCacheBytes = 256 * 1_024 * 1_024
    static let livePreviewShapeCacheBytes = 32 * 1_024 * 1_024

    static func boundedRasterScaleMultiplier(
        _ requestedMultiplier: CGFloat,
        logicalSize: CGSize,
        maximumTextureDimension: Int = Self.maximumTextureDimension
    ) -> CGFloat {
        let requested = max(requestedMultiplier, 1)
        let maxDimension = max(logicalSize.width, logicalSize.height, 1)
        let textureLimit = CGFloat(max(maximumTextureDimension, 1))
        return min(requested, max(textureLimit / maxDimension, 1))
    }

    static func boundedRasterScale(
        _ requestedScale: CGSize,
        logicalSize: CGSize,
        maximumTextureDimension: Int = Self.maximumTextureDimension
    ) -> CGSize {
        let textureLimit = CGFloat(max(maximumTextureDimension, 1))
        let logicalWidth = max(logicalSize.width, 1)
        let logicalHeight = max(logicalSize.height, 1)
        return CGSize(
            width: min(max(requestedScale.width, 1), max(textureLimit / logicalWidth, 1)),
            height: min(max(requestedScale.height, 1), max(textureLimit / logicalHeight, 1))
        )
    }

    static func canvasCoverageScale(
        logicalSize: CGSize,
        renderSize: CGSize
    ) -> CGSize {
        guard logicalSize.width > 0, logicalSize.height > 0,
            renderSize.width > 0, renderSize.height > 0
        else { return CGSize(width: 1, height: 1) }
        return CGSize(
            width: max(renderSize.width / logicalSize.width, 1),
            height: max(renderSize.height / logicalSize.height, 1)
        )
    }

    static func generatedLayerRasterScale(
        transformScale: CGSize,
        qualityScale: CGFloat,
        logicalSize: CGSize,
        renderSize: CGSize,
        maximumTextureDimension: Int = Self.maximumTextureDimension
    ) -> CGSize {
        let coverageScale = canvasCoverageScale(logicalSize: logicalSize, renderSize: renderSize)
        let canvasCoverageCap = CGSize(
            width: max(
                renderSize.width * maximumRasterizedCanvasCoverage / max(logicalSize.width, 1),
                1
            ),
            height: max(
                renderSize.height * maximumRasterizedCanvasCoverage / max(logicalSize.height, 1),
                1
            )
        )
        let cappedTransformScale = CGSize(
            width: min(max(transformScale.width, 1), canvasCoverageCap.width),
            height: min(max(transformScale.height, 1), canvasCoverageCap.height)
        )
        let requested = CGSize(
            width: max(cappedTransformScale.width, qualityScale, coverageScale.width, 1),
            height: max(cappedTransformScale.height, qualityScale, coverageScale.height, 1)
        )
        return boundedRasterScale(
            requested,
            logicalSize: logicalSize,
            maximumTextureDimension: maximumTextureDimension
        )
    }

    static func generatedLayerRasterScale(
        transformScale: CGFloat,
        qualityScale: CGFloat,
        logicalSize: CGSize,
        renderSize: CGSize,
        maximumTextureDimension: Int = Self.maximumTextureDimension
    ) -> CGFloat {
        let scale = generatedLayerRasterScale(
            transformScale: CGSize(width: transformScale, height: transformScale),
            qualityScale: qualityScale,
            logicalSize: logicalSize,
            renderSize: renderSize,
            maximumTextureDimension: maximumTextureDimension
        )
        return max(scale.width, scale.height)
    }
}

struct ShapeRasterLayout: Sendable, Equatable {
    static let maximumTextureDimension = GeneratedRasterPolicy.maximumTextureDimension

    let logicalSize: CGSize
    let logicalCornerRadius: CGFloat
    let rasterSize: CGSize
    let rasterCornerRadius: CGFloat
    let rasterScaleMultiplier: CGFloat
    let rasterScale: CGSize

    init(
        shape: ClipShape,
        at time: Double,
        logicalRenderScale: CGFloat,
        rasterScaleMultiplier requestedRasterScaleMultiplier: CGFloat,
        maximumTextureDimension: Int = Self.maximumTextureDimension
    ) {
        self.init(
            shape: shape,
            at: time,
            logicalRenderScale: logicalRenderScale,
            rasterScale: CGSize(
                width: requestedRasterScaleMultiplier,
                height: requestedRasterScaleMultiplier
            ),
            maximumTextureDimension: maximumTextureDimension
        )
    }

    init(
        shape: ClipShape,
        at time: Double,
        logicalRenderScale: CGFloat,
        rasterScale requestedRasterScale: CGSize,
        maximumTextureDimension: Int = Self.maximumTextureDimension
    ) {
        let logicalScale = max(logicalRenderScale, 0.000_001)
        let logicalWidth = max(CGFloat(shape.width.value(at: time)) * logicalScale, 1)
        let logicalHeight = max(CGFloat(shape.height.value(at: time)) * logicalScale, 1)
        let logicalRadius = min(
            max(CGFloat(shape.cornerRadius.value(at: time)) * logicalScale, 0),
            min(logicalWidth, logicalHeight) * 0.5
        )
        let logicalSize = CGSize(width: logicalWidth, height: logicalHeight)
        let boundedScale = GeneratedRasterPolicy.boundedRasterScale(
            requestedRasterScale,
            logicalSize: logicalSize,
            maximumTextureDimension: maximumTextureDimension
        )
        let rasterWidth = max(ceil(logicalWidth * boundedScale.width), 1)
        let rasterHeight = max(ceil(logicalHeight * boundedScale.height), 1)

        self.logicalSize = logicalSize
        self.logicalCornerRadius = logicalRadius
        self.rasterSize = CGSize(width: rasterWidth, height: rasterHeight)
        self.rasterCornerRadius = min(
            logicalRadius * min(boundedScale.width, boundedScale.height),
            min(rasterWidth, rasterHeight) * 0.5
        )
        self.rasterScaleMultiplier = max(boundedScale.width, boundedScale.height)
        self.rasterScale = boundedScale
    }
}

enum RenderFailurePolicy: Sendable {
    case skipUnavailableEffects
    case failOnUnavailableEffects
}

struct LivePreviewClipOverride: Sendable {
    var transform: ClipTransform?
    var isHidden = false
}

final class LivePreviewRenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var overrides: [UUID: LivePreviewClipOverride] = [:]
    private var forcesInteractiveQuality = false
    private var revision: UInt64 = 0

    @discardableResult
    func setTransform(_ transform: ClipTransform, for clipID: UUID) -> UInt64 {
        lock.lock()
        overrides[clipID, default: LivePreviewClipOverride()].transform = transform
        revision &+= 1
        let currentRevision = revision
        lock.unlock()
        return currentRevision
    }

    @discardableResult
    func setTransform(_ transform: ClipTransform, hidden isHidden: Bool, for clipID: UUID) -> UInt64 {
        lock.lock()
        overrides[clipID] = LivePreviewClipOverride(transform: transform, isHidden: isHidden)
        revision &+= 1
        let currentRevision = revision
        lock.unlock()
        return currentRevision
    }

    @discardableResult
    func setHidden(_ isHidden: Bool, for clipID: UUID) -> UInt64 {
        lock.lock()
        overrides[clipID, default: LivePreviewClipOverride()].isHidden = isHidden
        revision &+= 1
        let currentRevision = revision
        lock.unlock()
        return currentRevision
    }

    @discardableResult
    func revealPreservingTransform(for clipID: UUID) -> UInt64 {
        lock.lock()
        if overrides[clipID] != nil {
            overrides[clipID]?.isHidden = false
        }
        revision &+= 1
        let currentRevision = revision
        lock.unlock()
        return currentRevision
    }

    @discardableResult
    func clearTransform(for clipID: UUID) -> UInt64 {
        lock.lock()
        if overrides.removeValue(forKey: clipID) != nil {
            revision &+= 1
        }
        let currentRevision = revision
        lock.unlock()
        return currentRevision
    }

    @discardableResult
    func removeAll() -> UInt64 {
        lock.lock()
        if !overrides.isEmpty || forcesInteractiveQuality {
            overrides.removeAll(keepingCapacity: true)
            forcesInteractiveQuality = false
            revision &+= 1
        }
        let currentRevision = revision
        lock.unlock()
        return currentRevision
    }

    func transform(for clipID: UUID) -> ClipTransform? {
        lock.lock()
        let transform = overrides[clipID]?.transform
        lock.unlock()
        return transform
    }

    func override(for clipID: UUID) -> LivePreviewClipOverride? {
        lock.lock()
        let override = overrides[clipID]
        lock.unlock()
        return override
    }

    func isHidden(_ clipID: UUID) -> Bool {
        lock.lock()
        let isHidden = overrides[clipID]?.isHidden ?? false
        lock.unlock()
        return isHidden
    }

    var hasActiveOverrides: Bool {
        lock.lock()
        let hasOverrides = !overrides.isEmpty
        lock.unlock()
        return hasOverrides
    }

    @discardableResult
    func setInteractiveQualityOverride(_ isEnabled: Bool) -> UInt64 {
        lock.lock()
        if forcesInteractiveQuality != isEnabled {
            forcesInteractiveQuality = isEnabled
            revision &+= 1
        }
        let currentRevision = revision
        lock.unlock()
        return currentRevision
    }

    var usesInteractiveQuality: Bool {
        lock.lock()
        let isInteractive = forcesInteractiveQuality || !overrides.isEmpty
        lock.unlock()
        return isInteractive
    }
}

enum MetalRenderingError: LocalizedError {
    case metalUnavailable
    case commandQueueUnavailable
    case shaderLibraryUnavailable
    case shaderFunctionUnavailable(String)
    case pipelineCreationFailed(String, Error)
    case commandBufferUnavailable
    case commandBufferFailed(Error?)
    case pixelBufferTextureCreationFailed(OSStatus)
    case unsupportedPixelFormat(OSType)
    case textureAllocationFailed(width: Int, height: Int)
    case invalidRenderTarget
    case unavailableEffect(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            "This device does not provide the Metal features required by the rendering engine."
        case .commandQueueUnavailable:
            "The rendering engine could not create a Metal command queue."
        case .shaderLibraryUnavailable:
            "The Motionary Metal shader library is unavailable."
        case .shaderFunctionUnavailable(let name):
            "The required Metal shader \"\(name)\" is unavailable."
        case .pipelineCreationFailed(let name, let error):
            "The Metal pipeline \"\(name)\" could not be created: \(error.localizedDescription)"
        case .commandBufferUnavailable:
            "The rendering engine could not create a Metal command buffer."
        case .commandBufferFailed(let error):
            error.map { "Metal failed to render the frame: \($0.localizedDescription)" }
                ?? "Metal failed to render the frame."
        case .pixelBufferTextureCreationFailed(let status):
            "A video frame could not be shared with Metal (Core Video status \(status))."
        case .unsupportedPixelFormat(let format):
            "The video frame uses an unsupported pixel format (\(format))."
        case .textureAllocationFailed(let width, let height):
            "The rendering engine could not allocate a \(width) x \(height) GPU surface."
        case .invalidRenderTarget:
            "AVFoundation did not provide a valid render target."
        case .unavailableEffect(let name):
            "The active effect \"\(name)\" cannot be rendered on this device."
        case .cancelled:
            "Rendering was cancelled."
        }
    }
}

struct RenderViewport: Sendable {
    let visibleRect: CGRect
    let overscanRect: CGRect

    init(renderSize: CGSize, overscanFraction: CGFloat = 0.125) {
        let visible = CGRect(origin: .zero, size: renderSize)
        let insetX = -renderSize.width * max(overscanFraction, 0)
        let insetY = -renderSize.height * max(overscanFraction, 0)
        self.visibleRect = visible
        self.overscanRect = visible.insetBy(dx: insetX, dy: insetY)
    }

    init(visibleRect: CGRect, overscanRect: CGRect) {
        self.visibleRect = visibleRect
        self.overscanRect = overscanRect
    }
}

struct FrameRenderPlan: @unchecked Sendable {
    let renderSize: CGSize
    let renderScale: CGFloat
    let vectorRenderScale: CGFloat
    let viewport: RenderViewport
    let backgroundColor: RGBAColor
    let frameDuration: Double
    let clips: [RenderClipDescriptor]
    let clipIntervals: [RenderClipInterval]
    let quality: RenderQualityProfile
    let failurePolicy: RenderFailurePolicy
    let livePreviewState: LivePreviewRenderState?

    init(
        renderSize: CGSize,
        renderScale: CGFloat,
        vectorRenderScale: CGFloat? = nil,
        viewport: RenderViewport? = nil,
        backgroundColor: RGBAColor,
        frameDuration: Double,
        clips: [RenderClipDescriptor],
        clipIntervals: [RenderClipInterval] = [],
        quality: RenderQualityProfile,
        failurePolicy: RenderFailurePolicy,
        livePreviewState: LivePreviewRenderState? = nil
    ) {
        self.renderSize = renderSize
        self.renderScale = renderScale
        self.vectorRenderScale = max(vectorRenderScale ?? renderScale, renderScale, 0.000_001)
        self.viewport = viewport ?? RenderViewport(renderSize: renderSize)
        self.backgroundColor = backgroundColor
        self.frameDuration = frameDuration
        self.clips = clips
        self.clipIntervals = clipIntervals
        self.quality = quality
        self.failurePolicy = failurePolicy
        self.livePreviewState = livePreviewState
    }
}

enum RenderPlanCompiler {
    static func compile(
        _ instruction: MotionaryVideoCompositionInstruction,
        quality: RenderQualityProfile? = nil,
        failurePolicy: RenderFailurePolicy? = nil
    ) -> FrameRenderPlan {
        return FrameRenderPlan(
            renderSize: instruction.renderSize,
            renderScale: instruction.renderScale,
            vectorRenderScale: instruction.vectorRenderScale,
            viewport: instruction.viewport,
            backgroundColor: instruction.backgroundColor,
            frameDuration: instruction.frameDuration,
            clips: instruction.clips,
            clipIntervals: instruction.clipIntervals,
            quality: quality
                ?? (instruction.livePreviewState?.usesInteractiveQuality == true
                    ? .interactive
                    : instruction.qualityProfile),
            failurePolicy: failurePolicy ?? instruction.failurePolicy,
            livePreviewState: instruction.livePreviewState
        )
    }
}

extension RenderClipDescriptor {
    func resolvingLiveOverride(from state: LivePreviewRenderState?) -> RenderClipDescriptor {
        guard let override = state?.override(for: clipID) else { return self }
        var transform = override.transform ?? self.transform
        if override.isHidden {
            transform.opacity = AnimatableProperty(baseValue: 0)
        }
        return RenderClipDescriptor(
            trackID: trackID,
            backgroundMaskTrackID: backgroundMaskTrackID,
            stillImageURL: stillImageURL,
            clipID: clipID,
            timelineStart: timelineStart,
            duration: duration,
            sourceTransform: sourceTransform,
            backgroundMaskSourceTransform: backgroundMaskSourceTransform,
            transform: transform,
            adjustments: adjustments,
            effectStack: effectStack,
            mask: mask,
            backgroundRemoval: backgroundRemoval,
            blendMode: blendMode,
            blendIntensity: blendIntensity,
            shape: shape,
            text: text,
            renderOrder: renderOrder
        )
    }
}

struct EffectRenderContext: Sendable {
    let compositionTime: Double
    let clipTime: Double
    let frameIndex: Int64
    let itemID: UUID
    let renderScale: CGFloat
    let quality: RenderQualityProfile

    func deterministicSeed(storedSeed: UInt64, effectID: UUID) -> UInt32 {
        var value = storedSeed
        value ^= Self.fnv1a(itemID.uuidString.utf8)
        value = Self.mix(value ^ Self.fnv1a(effectID.uuidString.utf8))
        value = Self.mix(value ^ UInt64(bitPattern: frameIndex))
        return UInt32(truncatingIfNeeded: value ^ (value >> 32))
    }

    private static func fnv1a<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        bytes.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static func mix(_ input: UInt64) -> UInt64 {
        var value = input
        value ^= value >> 30
        value &*= 0xbf58_476d_1ce4_e5b9
        value ^= value >> 27
        value &*= 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
}

struct EffectRenderResult {
    let image: CIImage
    let requiredMargin: CGFloat

    init(image: CIImage, requiredMargin: CGFloat = 0) {
        self.image = image
        self.requiredMargin = max(requiredMargin, 0)
    }
}

struct MotionaryEffectUniforms {
    var size: SIMD2<UInt32>
    var effectKind: UInt32
    var seed: UInt32
    var time: Float
    var frameIndex: Float
    var direction: SIMD2<Float>
    var parameters: SIMD4<Float>
}

struct MotionaryYUVUniforms {
    var size: SIMD2<UInt32>
    var fullRange: UInt32
    var matrix: UInt32
}

enum MotionaryMetalEffectKind: UInt32 {
    case prismSplit = 0
    case analogGlitch = 1
    case bleachBypass = 2
    case cineTeal = 3
    case kodakPrint = 4
    case portraSoft = 5
    case coolFade = 6
    case matteContrast = 7
    case fineGrain = 8
    case lightLeak = 9
    case chromaticAberration = 10
    case barrelWarp = 11
    case cinematicBloom = 20
    case filmHalation = 21
    case softGlow = 22
    case anamorphicFlare = 23
}

struct EffectRenderDiagnostic: Equatable, Sendable {
    enum Severity: String, Equatable, Sendable {
        case info
        case warning
        case error
    }

    let severity: Severity
    let moduleID: String
    let effectID: UUID
    let message: String
}

final class EffectRenderDiagnostics: @unchecked Sendable {
    static let shared = EffectRenderDiagnostics()
    private typealias Handler = @Sendable (EffectRenderDiagnostic) -> Void

    private let lock = NSLock()
    private var handlers: [UUID: Handler] = [:]
    private let logger = Logger(subsystem: "com.moysoft.motionary", category: "Rendering")

    @discardableResult
    func installHandler(
        _ handler: @escaping @Sendable (EffectRenderDiagnostic) -> Void
    ) -> UUID {
        let token = UUID()
        lock.lock()
        handlers[token] = handler
        lock.unlock()
        return token
    }

    func removeHandler(_ token: UUID) {
        lock.lock()
        handlers.removeValue(forKey: token)
        lock.unlock()
    }

    func report(_ diagnostic: EffectRenderDiagnostic) {
        switch diagnostic.severity {
        case .info:
            logger.info("Effect \(diagnostic.moduleID, privacy: .public): \(diagnostic.message, privacy: .public)")
        case .warning:
            logger.warning("Effect \(diagnostic.moduleID, privacy: .public): \(diagnostic.message, privacy: .public)")
        case .error:
            logger.error("Effect \(diagnostic.moduleID, privacy: .public): \(diagnostic.message, privacy: .public)")
        }
        lock.lock()
        let currentHandlers = Array(handlers.values)
        lock.unlock()
        currentHandlers.forEach { $0(diagnostic) }
    }
}
