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

enum RenderFailurePolicy: Sendable, Equatable {
    case skipUnavailableEffects
    case failOnUnavailableEffects
}

/// Frame-local editor state layered over an immutable render descriptor.
///
/// Visual inspector changes intentionally live here while an interaction is
/// active. This lets the compositor render the current effect/mask/blend stack
/// without rebuilding the AVFoundation composition graph for every drag tick.
struct LivePreviewClipOverride: @unchecked Sendable {
    var transform: ClipTransform?
    var visuals: TimelineItemVisuals?
    var shape: ClipShape?
    var text: TextTimelineItem?
    var isHidden = false

    fileprivate var isEmpty: Bool {
        transform == nil
            && visuals == nil
            && shape == nil
            && text == nil
            && !isHidden
    }
}

struct LivePreviewRenderSnapshot: Sendable {
    let overrides: [UUID: LivePreviewClipOverride]
    let usesInteractiveQuality: Bool
    let revision: UInt64

    func override(for clipID: UUID) -> LivePreviewClipOverride? {
        overrides[clipID]
    }
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
        overrides[clipID, default: LivePreviewClipOverride()].transform = transform
        overrides[clipID]?.isHidden = isHidden
        revision &+= 1
        let currentRevision = revision
        lock.unlock()
        return currentRevision
    }

    /// Installs a complete render-facing visual override while retaining any
    /// direct canvas transform or hidden handoff already active for the clip.
    ///
    /// Shape and text payloads are supplied for their respective generated
    /// layer types so inspector edits to vector/text data appear in the very
    /// next requested frame without descriptor recompilation.
    @discardableResult
    func setVisuals(
        _ visuals: TimelineItemVisuals,
        shape: ClipShape? = nil,
        text: TextTimelineItem? = nil,
        for clipID: UUID
    ) -> UInt64 {
        lock.lock()
        var override = overrides[clipID] ?? LivePreviewClipOverride()
        override.visuals = visuals
        override.shape = shape
        override.text = text
        overrides[clipID] = override
        revision &+= 1
        let currentRevision = revision
        lock.unlock()
        return currentRevision
    }

    @discardableResult
    func setHidden(_ isHidden: Bool, for clipID: UUID) -> UInt64 {
        lock.lock()
        if isHidden {
            if overrides[clipID]?.isHidden != true {
                overrides[clipID, default: LivePreviewClipOverride()].isHidden = true
                revision &+= 1
            }
        } else if overrides[clipID]?.isHidden == true {
            overrides[clipID]?.isHidden = false
            if overrides[clipID]?.isEmpty == true {
                overrides.removeValue(forKey: clipID)
            }
            revision &+= 1
        }
        let currentRevision = revision
        lock.unlock()
        return currentRevision
    }

    @discardableResult
    func revealPreservingTransform(for clipID: UUID) -> UInt64 {
        lock.lock()
        if overrides[clipID]?.isHidden == true {
            overrides[clipID]?.isHidden = false
            if overrides[clipID]?.isEmpty == true {
                overrides.removeValue(forKey: clipID)
            }
            revision &+= 1
        }
        let currentRevision = revision
        lock.unlock()
        return currentRevision
    }

    @discardableResult
    func clearTransform(for clipID: UUID) -> UInt64 {
        lock.lock()
        if overrides[clipID]?.transform != nil {
            overrides[clipID]?.transform = nil
            if overrides[clipID]?.isEmpty == true {
                overrides.removeValue(forKey: clipID)
            }
            revision &+= 1
        }
        let currentRevision = revision
        lock.unlock()
        return currentRevision
    }

    /// Clears only inspector-driven visual data. A concurrent canvas
    /// transform/hidden handoff remains active until its own commit completes.
    @discardableResult
    func clearVisuals(for clipID: UUID) -> UInt64 {
        lock.lock()
        if let existing = overrides[clipID],
            existing.visuals != nil || existing.shape != nil || existing.text != nil
        {
            overrides[clipID]?.visuals = nil
            overrides[clipID]?.shape = nil
            overrides[clipID]?.text = nil
            if overrides[clipID]?.isEmpty == true {
                overrides.removeValue(forKey: clipID)
            }
            revision &+= 1
        }
        let currentRevision = revision
        lock.unlock()
        return currentRevision
    }

    /// Clears the complete handoff for a clip after both its persistent
    /// descriptor and presentation state have committed.
    @discardableResult
    func clearOverride(for clipID: UUID) -> UInt64 {
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
        let isInteractive = forcesInteractiveQuality
        lock.unlock()
        return isInteractive
    }

    func snapshot() -> LivePreviewRenderSnapshot {
        lock.lock()
        let snapshot = LivePreviewRenderSnapshot(
            overrides: overrides,
            usesInteractiveQuality: forcesInteractiveQuality,
            revision: revision
        )
        lock.unlock()
        return snapshot
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
    let clipIntervals: RenderClipIntervalIndex
    let textClipsByStart: [RenderClipDescriptor]
    let quality: RenderQualityProfile
    let failurePolicy: RenderFailurePolicy
    let livePreviewState: LivePreviewRenderState?
    let livePreviewSnapshot: LivePreviewRenderSnapshot?

    init(
        renderSize: CGSize,
        renderScale: CGFloat,
        vectorRenderScale: CGFloat? = nil,
        viewport: RenderViewport? = nil,
        backgroundColor: RGBAColor,
        frameDuration: Double,
        clips: [RenderClipDescriptor],
        clipIntervals: RenderClipIntervalIndex = RenderClipIntervalIndex(),
        textClipsByStart: [RenderClipDescriptor]? = nil,
        quality: RenderQualityProfile,
        failurePolicy: RenderFailurePolicy,
        livePreviewState: LivePreviewRenderState? = nil,
        livePreviewSnapshot: LivePreviewRenderSnapshot? = nil
    ) {
        self.renderSize = renderSize
        self.renderScale = renderScale
        self.vectorRenderScale = max(vectorRenderScale ?? renderScale, renderScale, 0.000_001)
        self.viewport = viewport ?? RenderViewport(renderSize: renderSize)
        self.backgroundColor = backgroundColor
        self.frameDuration = frameDuration
        self.clips = clips
        self.clipIntervals = clipIntervals
        self.textClipsByStart = textClipsByStart ?? clips
            .filter { $0.text != nil }
            .sorted {
                if $0.timelineStart == $1.timelineStart {
                    return $0.renderOrder < $1.renderOrder
                }
                return $0.timelineStart < $1.timelineStart
            }
        self.quality = quality
        self.failurePolicy = failurePolicy
        self.livePreviewState = livePreviewState
        self.livePreviewSnapshot = livePreviewSnapshot ?? livePreviewState?.snapshot()
    }
}

enum RenderPlanCompiler {
    static func compile(
        _ instruction: MotionaryVideoCompositionInstruction,
        quality: RenderQualityProfile? = nil,
        failurePolicy: RenderFailurePolicy? = nil
    ) -> FrameRenderPlan {
        let livePreviewSnapshot = instruction.livePreviewState?.snapshot()
        return FrameRenderPlan(
            renderSize: instruction.renderSize,
            renderScale: instruction.renderScale,
            vectorRenderScale: instruction.vectorRenderScale,
            viewport: instruction.viewport,
            backgroundColor: instruction.backgroundColor,
            frameDuration: instruction.frameDuration,
            clips: instruction.clips,
            clipIntervals: instruction.clipIntervals,
            textClipsByStart: instruction.textClipsByStart,
            quality: quality
                ?? (livePreviewSnapshot?.usesInteractiveQuality == true
                    ? .interactive
                    : instruction.qualityProfile),
            failurePolicy: failurePolicy ?? instruction.failurePolicy,
            livePreviewState: instruction.livePreviewState,
            livePreviewSnapshot: livePreviewSnapshot
        )
    }
}

extension RenderClipDescriptor {
    func resolvingLiveOverride(from snapshot: LivePreviewRenderSnapshot?) -> RenderClipDescriptor {
        guard let override = snapshot?.override(for: clipID) else { return self }
        let visuals = override.visuals
        var transform = override.transform ?? visuals?.transform ?? self.transform
        let hasTransientRasterScaleOverride = self.hasTransientRasterScaleOverride
            || transform.scale != self.transform.scale
        var resolvedMask = mask
        var resolvedBackgroundRemoval = backgroundRemoval
        if let visuals {
            resolvedMask = visuals.mask
            resolvedBackgroundRemoval = visuals.backgroundRemoval
        }
        if override.isHidden {
            transform.opacity = AnimatableProperty(baseValue: 0)
        }
        return RenderClipDescriptor(
            trackID: trackID,
            backgroundMaskTrackID: backgroundMaskTrackID,
            stillImageURL: stillImageURL,
            stillImageCacheIdentity: stillImageCacheIdentity,
            clipID: clipID,
            timelineStart: timelineStart,
            duration: duration,
            sourceTransform: sourceTransform,
            backgroundMaskSourceTransform: backgroundMaskSourceTransform,
            transform: transform,
            adjustments: visuals?.adjustments ?? adjustments,
            effectStack: visuals?.effectStack ?? effectStack,
            mask: resolvedMask,
            backgroundRemoval: resolvedBackgroundRemoval,
            blendMode: visuals?.blendMode ?? blendMode,
            blendIntensity: visuals?.blendIntensity ?? blendIntensity,
            shape: override.shape ?? shape,
            text: override.text ?? text,
            role: role,
            hasTransientRasterScaleOverride: hasTransientRasterScaleOverride,
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
    private struct Signature: Hashable {
        let severity: String
        let moduleID: String
        let effectID: UUID
        let message: String
    }

    private let lock = NSLock()
    private var handlers: [UUID: Handler] = [:]
    private var lastEmissionTimes: [Signature: TimeInterval] = [:]
    private let repeatInterval: TimeInterval
    private let maximumRetainedSignatures: Int
    private let clock: () -> TimeInterval
    private let logger = Logger(subsystem: "com.moysoft.motionary", category: "Rendering")

    init(
        repeatInterval: TimeInterval = 1,
        maximumRetainedSignatures: Int = 256,
        clock: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.repeatInterval = max(repeatInterval, 0)
        self.maximumRetainedSignatures = max(maximumRetainedSignatures, 1)
        self.clock = clock
    }

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
        let signature = Signature(
            severity: diagnostic.severity.rawValue,
            moduleID: diagnostic.moduleID,
            effectID: diagnostic.effectID,
            message: diagnostic.message
        )
        let now = clock()
        lock.lock()
        if let lastEmission = lastEmissionTimes[signature],
            now >= lastEmission,
            now - lastEmission < repeatInterval
        {
            lock.unlock()
            return
        }
        lastEmissionTimes[signature] = now
        if lastEmissionTimes.count > maximumRetainedSignatures,
            let oldest = lastEmissionTimes.min(by: { $0.value < $1.value })?.key
        {
            lastEmissionTimes.removeValue(forKey: oldest)
        }
        let currentHandlers = Array(handlers.values)
        lock.unlock()

        switch diagnostic.severity {
        case .info:
            logger.info("Effect \(diagnostic.moduleID, privacy: .public): \(diagnostic.message, privacy: .public)")
        case .warning:
            logger.warning("Effect \(diagnostic.moduleID, privacy: .public): \(diagnostic.message, privacy: .public)")
        case .error:
            logger.error("Effect \(diagnostic.moduleID, privacy: .public): \(diagnostic.message, privacy: .public)")
        }
        currentHandlers.forEach { $0(diagnostic) }
    }

    var retainedSignatureCount: Int {
        lock.lock()
        let count = lastEmissionTimes.count
        lock.unlock()
        return count
    }
}
