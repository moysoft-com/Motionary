// AVFoundation composition construction shared by preview and export.

@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import os
import UIKit

private let compositionMetricsLog = OSLog(
    subsystem: "com.moysoft.motionary",
    category: .pointsOfInterest
)

private final class StillImageValidationCache: @unchecked Sendable {
    private final class Entry: NSObject {
        let identity: String

        init(identity: String) {
            self.identity = identity
        }
    }

    private let entries: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 128
        return cache
    }()

    /// Returns an immutable identity that can be embedded in the render
    /// descriptor. Imported project media is immutable for the lifetime of its
    /// URL, so subsequent visual-only descriptor recompilations avoid even
    /// filesystem metadata reads on the main actor.
    func validatedIdentity(for url: URL) -> String? {
        let pathKey = url.standardizedFileURL.path as NSString
        if let cached = entries.object(forKey: pathKey) {
            return cached.identity
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
        ])
        let fileSize = values?.fileSize ?? -1
        let modifiedAt = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? -1
        let fileID = values?.fileResourceIdentifier.map { "\($0)" } ?? "unidentified"
        let identity = "\(pathKey)|\(fileID)|\(fileSize)|\(modifiedAt)"
        guard Self.validateStillImageFile(url) else { return nil }
        entries.setObject(Entry(identity: identity), forKey: pathKey)
        return identity
    }

    private static func validateStillImageFile(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0,
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
        else { return false }

        // Decode a tiny thumbnail once per immutable file identity. Merely
        // opening the container would allow corrupt payloads into the renderer.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 8,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) != nil
    }
}

enum VideoSourceGeometry {
    /// Native Core Image images use bottom-left coordinates. The existing
    /// compositor graph uses Metal texture rows, with the first row at y=0.
    /// Apply the same conversion to decoder buffers and time-addressed samples.
    static func engineImage(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: 0, y: image.extent.minY + image.extent.maxY)
            .scaledBy(x: 1, y: -1))
    }

    static func displayRect(naturalSize: CGSize, transform: CGAffineTransform) -> CGRect {
        CGRect(origin: .zero, size: naturalSize)
            .applying(transform)
            .standardized
    }

    static func normalizedTransform(
        naturalSize: CGSize,
        transform: CGAffineTransform
    ) -> CGAffineTransform {
        let displayRect = displayRect(naturalSize: naturalSize, transform: transform)
        return transform.concatenating(
            CGAffineTransform(
                translationX: -displayRect.minX,
                y: -displayRect.minY
            )
        )
    }

    static func fitScale(sourceSize: CGSize, inside containerSize: CGSize) -> CGFloat? {
        guard sourceSize.width > 0, sourceSize.height > 0,
            containerSize.width > 0, containerSize.height > 0
        else { return nil }
        return min(
            containerSize.width / sourceSize.width,
            containerSize.height / sourceSize.height
        )
    }

    static func fittedSize(sourceSize: CGSize, inside containerSize: CGSize) -> CGSize? {
        guard let scale = fitScale(sourceSize: sourceSize, inside: containerSize) else {
            return nil
        }
        return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    }
}

enum CompositionAudioPolicy {
    /// Source audio remains in the topology even when its current envelope is
    /// zero, so later keyframes and edits do not require rebuilding tracks.
    static func includesSourceAudio(for mediaType: ClipMediaType) -> Bool {
        mediaType == .video
    }
}

/// Composition output and associated custom video-composition metadata.
struct RenderedComposition {
    var composition: AVMutableComposition
    var videoComposition: AVVideoComposition?
    var audioMix: AVAudioMix?
    var duration: Double
    var hasVideo: Bool
    var videoClockTrackID: CMPersistentTrackID?
    var visualTrackIDs: [UUID: CMPersistentTrackID] = [:]
    var audioTrackIDs: [UUID: CMPersistentTrackID] = [:]
    var sourceTransforms: [UUID: CGAffineTransform] = [:]
    var backgroundMaskTrackIDs: [UUID: CMPersistentTrackID] = [:]
    var backgroundMaskTransforms: [UUID: CGAffineTransform] = [:]
}

/// Defines how a render descriptor participates in the layer stack.
///
/// Content layers contribute new pixels. An adjustment layer instead samples
/// the composite accumulated below its stack position and transforms that
/// result. Keeping the role explicit prevents source-less adjustment layers
/// from silently falling through the generated-overlay path.
enum RenderLayerRole: Sendable, Equatable {
    case content
    case adjustment
}

/// Per-clip information consumed by the custom video compositor.
struct RenderClipDescriptor: @unchecked Sendable {
    var depthAnalyses: [UUID: DepthBakeStore.Analysis] = [:]
    var layerID: UUID? = nil
    var adjustmentTargets: AdjustmentLayerTargets = AdjustmentLayerTargets()
    let trackID: CMPersistentTrackID
    let backgroundMaskTrackID: CMPersistentTrackID?
    /// Non-video visual sources are decoded once by the frame engine and use
    /// the shared composition clock instead of a synthetic per-item movie.
    let backgroundMaskImageURL: URL?
    let stillImageURL: URL?
    /// Immutable file identity prepared outside the frame-rendering path.
    let stillImageCacheIdentity: String?
    let clipID: UUID
    let timelineStart: Double
    let duration: Double
    let sourceTransform: CGAffineTransform
    let backgroundMaskSourceTransform: CGAffineTransform
    let transform: ClipTransform
    let adjustments: AdjustmentSettings
    let effectStack: EffectStack
    let depthEffects: EffectStack
    let contentEffects: EffectStack
    let hasObjectMotionBlur: Bool
    let mask: ItemMask?
    let backgroundRemoval: BackgroundRemovalSettings?
    let blendMode: BlendMode
    let blendIntensity: Double
    let shape: ClipShape?
    let text: TextTimelineItem?
    let role: RenderLayerRole
    /// Set only on a frame-local live override when its scale differs from the
    /// persistent descriptor. Position/rotation-only interaction can continue
    /// to reuse the cached shape texture.
    let hasTransientRasterScaleOverride: Bool
    let renderOrder: Int
    let temporalSource: EffectTemporalSource?

    var isAdjustmentLayer: Bool { role == .adjustment }

    init(
        trackID: CMPersistentTrackID,
        backgroundMaskTrackID: CMPersistentTrackID?,
        backgroundMaskImageURL: URL? = nil,
        stillImageURL: URL? = nil,
        stillImageCacheIdentity: String? = nil,
        clipID: UUID,
        timelineStart: Double,
        duration: Double,
        sourceTransform: CGAffineTransform,
        backgroundMaskSourceTransform: CGAffineTransform,
        transform: ClipTransform,
        adjustments: AdjustmentSettings,
        effectStack: EffectStack,
        mask: ItemMask?,
        backgroundRemoval: BackgroundRemovalSettings?,
        blendMode: BlendMode,
        blendIntensity: Double,
        shape: ClipShape?,
        text: TextTimelineItem?,
        role: RenderLayerRole = .content,
        hasTransientRasterScaleOverride: Bool = false,
        renderOrder: Int,
        temporalSource: EffectTemporalSource? = nil
    ) {
        self.trackID = trackID
        self.backgroundMaskTrackID = backgroundMaskTrackID
        self.backgroundMaskImageURL = backgroundMaskImageURL
        self.stillImageURL = stillImageURL
        self.stillImageCacheIdentity = stillImageCacheIdentity
        self.clipID = clipID
        self.timelineStart = timelineStart
        self.duration = duration
        self.sourceTransform = sourceTransform
        self.backgroundMaskSourceTransform = backgroundMaskSourceTransform
        self.transform = transform
        self.adjustments = adjustments
        self.effectStack = effectStack
        var depth = EffectStack()
        var content = EffectStack()
        var motionBlur = false
        for effect in effectStack.effects {
            if effect.moduleID == .depthMap {
                depth.effects.append(effect)
            } else {
                content.effects.append(effect)
                motionBlur = motionBlur || (effect.isEnabled && effect.moduleID == .motionBlur)
            }
        }
        self.depthEffects = depth
        self.contentEffects = content
        self.hasObjectMotionBlur = motionBlur
        self.mask = mask
        self.backgroundRemoval = backgroundRemoval
        self.blendMode = blendMode
        self.blendIntensity = blendIntensity
        self.shape = shape
        self.text = text
        self.role = role
        self.hasTransientRasterScaleOverride = hasTransientRasterScaleOverride
        self.renderOrder = renderOrder
        var temporalSource = temporalSource
        temporalSource?.adjustments = adjustments
        temporalSource?.backgroundRemoval = backgroundRemoval
        temporalSource?.sourceOrientation = sourceTransform
        temporalSource?.matteOrientation = backgroundMaskSourceTransform
        self.temporalSource = temporalSource
    }
}

/// Immutable interval tree for half-open clip ranges.
///
/// Every clip is stored once as a normalized span and at exactly one tree
/// node. Node lookup arrays contain integer indices only, keeping storage O(n)
/// even for thousands of heavily overlapping layers.
struct RenderClipIntervalIndex: Sendable {
    private struct ClipSpan: Sendable {
        let clipIndex: Int
        let start: Double
        let end: Double
    }

    private indirect enum Node: Sendable {
        case branch(
            center: Double,
            byStart: [Int],
            byEndDescending: [Int],
            left: Node?,
            right: Node?
        )

        var storageEntryCount: Int {
            switch self {
            case .branch(_, let byStart, let byEndDescending, let left, let right):
                byStart.count
                    + byEndDescending.count
                    + (left?.storageEntryCount ?? 0)
                    + (right?.storageEntryCount ?? 0)
            }
        }
    }

    private let spans: [ClipSpan]
    private let root: Node?

    init() {
        spans = []
        root = nil
    }

    init(clips: [RenderClipDescriptor], duration: Double) {
        let safeDuration = duration.isFinite ? max(duration, 0) : 0
        let normalizedSpans: [ClipSpan] = clips.enumerated().compactMap {
            (index: Int, clip: RenderClipDescriptor) -> ClipSpan? in
            let rawStart = clip.timelineStart.isFinite ? clip.timelineStart : 0
            let rawDuration = clip.duration.isFinite ? max(clip.duration, 0) : 0
            let start = min(max(rawStart, 0), safeDuration)
            let end = min(max(rawStart + rawDuration, 0), safeDuration)
            guard end > start else { return nil }
            return ClipSpan(clipIndex: index, start: start, end: end)
        }
        spans = normalizedSpans
        root = Self.makeNode(
            spanIndices: Array(normalizedSpans.indices),
            spans: normalizedSpans
        )
    }

    var isEmpty: Bool { spans.isEmpty }
    var count: Int { spans.count }

    /// Exposed to focused tests so a regression to per-interval descriptor
    /// snapshots is detected without relying on allocator-specific metrics.
    var storageEntryCount: Int {
        spans.count + (root?.storageEntryCount ?? 0)
    }

    func activeClipIndices(at time: Double) -> [Int] {
        guard time.isFinite, let root else { return [] }
        var result: [Int] = []
        Self.collectActive(
            at: time,
            node: root,
            spans: spans,
            result: &result
        )
        result.sort()
        return result
    }

    private static func makeNode(
        spanIndices: [Int],
        spans: [ClipSpan]
    ) -> Node? {
        guard !spanIndices.isEmpty else { return nil }
        let centers = spanIndices
            .map { (spans[$0].start + spans[$0].end) * 0.5 }
            .sorted()
        let center = centers[centers.count / 2]
        var left: [Int] = []
        var right: [Int] = []
        var spanning: [Int] = []
        left.reserveCapacity(spanIndices.count / 2)
        right.reserveCapacity(spanIndices.count / 2)
        spanning.reserveCapacity(spanIndices.count)

        for spanIndex in spanIndices {
            let span = spans[spanIndex]
            if span.end <= center {
                left.append(spanIndex)
            } else if span.start > center {
                right.append(spanIndex)
            } else {
                spanning.append(spanIndex)
            }
        }

        let byStart = spanning.sorted {
            let lhs = spans[$0]
            let rhs = spans[$1]
            return lhs.start == rhs.start
                ? lhs.clipIndex < rhs.clipIndex
                : lhs.start < rhs.start
        }
        let byEndDescending = spanning.sorted {
            let lhs = spans[$0]
            let rhs = spans[$1]
            return lhs.end == rhs.end
                ? lhs.clipIndex < rhs.clipIndex
                : lhs.end > rhs.end
        }
        return .branch(
            center: center,
            byStart: byStart,
            byEndDescending: byEndDescending,
            left: makeNode(spanIndices: left, spans: spans),
            right: makeNode(spanIndices: right, spans: spans)
        )
    }

    private static func collectActive(
        at time: Double,
        node: Node,
        spans: [ClipSpan],
        result: inout [Int]
    ) {
        switch node {
        case .branch(let center, let byStart, let byEndDescending, let left, let right):
            if time < center {
                for spanIndex in byStart {
                    let span = spans[spanIndex]
                    guard span.start <= time else { break }
                    result.append(span.clipIndex)
                }
                if let left {
                    collectActive(at: time, node: left, spans: spans, result: &result)
                }
            } else {
                for spanIndex in byEndDescending {
                    let span = spans[spanIndex]
                    guard span.end > time else { break }
                    result.append(span.clipIndex)
                }
                if let right {
                    collectActive(at: time, node: right, spans: spans, result: &result)
                }
            }
        }
    }
}

/// Video composition instruction containing all clips active in a render interval.
final class MotionaryVideoCompositionInstruction:
    NSObject,
    AVVideoCompositionInstructionProtocol,
    NSCopying,
    @unchecked Sendable
{
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let clips: [RenderClipDescriptor]
    let clipIntervals: RenderClipIntervalIndex
    let textClipsByStart: [RenderClipDescriptor]
    let renderSize: CGSize
    let renderScale: CGFloat
    let vectorRenderScale: CGFloat
    let viewport: RenderViewport
    let backgroundColor: RGBAColor
    let frameDuration: Double
    let qualityProfile: RenderQualityProfile
    let previewFrameTimeoutMilliseconds: Int
    let failurePolicy: RenderFailurePolicy
    let livePreviewState: LivePreviewRenderState?
    let renderSessionID: UUID

    init(
        timeRange: CMTimeRange,
        clips: [RenderClipDescriptor],
        sourceTrackIDs: [CMPersistentTrackID],
        renderSize: CGSize,
        renderScale: CGFloat,
        vectorRenderScale: CGFloat? = nil,
        viewport: RenderViewport? = nil,
        backgroundColor: RGBAColor,
        frameDuration: Double,
        qualityProfile: RenderQualityProfile = .balanced,
        failurePolicy: RenderFailurePolicy = .skipUnavailableEffects,
        livePreviewState: LivePreviewRenderState? = nil,
        renderSessionID: UUID = UUID()
    ) {
        self.timeRange = timeRange
        self.clips = clips.sorted { $0.renderOrder < $1.renderOrder }
        self.textClipsByStart = self.clips
            .filter { $0.text != nil }
            .sorted {
                if $0.timelineStart == $1.timelineStart {
                    return $0.renderOrder < $1.renderOrder
                }
                return $0.timelineStart < $1.timelineStart
            }
        let intervalCompilationStartedAt = ProcessInfo.processInfo.systemUptime
        self.clipIntervals = RenderClipIntervalIndex(
            clips: self.clips,
            duration: CMTimeGetSeconds(timeRange.duration)
        )
        let intervalCompilationMicroseconds = Int(
            (ProcessInfo.processInfo.systemUptime - intervalCompilationStartedAt) * 1_000_000
        )
        os_signpost(
            .event,
            log: compositionMetricsLog,
            name: "Compile Clip Intervals",
            "clips=%d indexed=%d duration_us=%d",
            self.clips.count,
            self.clipIntervals.count,
            intervalCompilationMicroseconds
        )
        self.renderSize = renderSize
        self.renderScale = renderScale
        self.vectorRenderScale = max(vectorRenderScale ?? renderScale, renderScale, 0.000_001)
        self.viewport = viewport ?? RenderViewport(renderSize: renderSize)
        self.backgroundColor = backgroundColor
        self.frameDuration = frameDuration
        self.qualityProfile = qualityProfile
        // Only the threshold matters. Large projects already exceed it by
        // clip count alone, and interval instructions share the same budget.
        var cost = clips.count
        for clip in clips {
            guard cost <= 8 else { break }
            cost += 2 * clip.effectStack.effects.lazy.filter(\.isEnabled).count
            cost += clip.text == nil ? 0 : 2
            cost += clip.isAdjustmentLayer ? 2 : 0
        }
        switch qualityProfile {
        case .interactive: previewFrameTimeoutMilliseconds = cost > 8 ? 1_800 : 1_200
        case .balanced: previewFrameTimeoutMilliseconds = cost > 8 ? 4_000 : 2_500
        case .export: previewFrameTimeoutMilliseconds = 5_000
        }
        self.failurePolicy = failurePolicy
        self.livePreviewState = livePreviewState
        self.renderSessionID = renderSessionID
        self.requiredSourceTrackIDs = sourceTrackIDs
            .filter { $0 != kCMPersistentTrackID_Invalid }
            .map { NSNumber(value: $0) }
        super.init()
    }

    /// Interval instructions share the immutable descriptor/index storage.
    /// Only decoder dependencies change at source boundaries.
    init(timeRange: CMTimeRange, template: MotionaryVideoCompositionInstruction,
         sourceTrackIDs: [CMPersistentTrackID]) {
        self.timeRange = timeRange
        clips = template.clips
        clipIntervals = template.clipIntervals
        textClipsByStart = template.textClipsByStart
        renderSize = template.renderSize
        renderScale = template.renderScale
        vectorRenderScale = template.vectorRenderScale
        viewport = template.viewport
        backgroundColor = template.backgroundColor
        frameDuration = template.frameDuration
        qualityProfile = template.qualityProfile
        previewFrameTimeoutMilliseconds = template.previewFrameTimeoutMilliseconds
        failurePolicy = template.failurePolicy
        livePreviewState = template.livePreviewState
        renderSessionID = template.renderSessionID
        requiredSourceTrackIDs = sourceTrackIDs.map { NSNumber(value: $0) }
        super.init()
    }

    /// AVPlayer defensively copies custom instructions while installing a
    /// video composition. The instruction is immutable, so retaining the same
    /// instance is safe and avoids duplicating its interval index.
    func copy(with zone: NSZone? = nil) -> Any {
        self
    }

    func activeClips(at time: Double) -> [RenderClipDescriptor] {
        var active = clipIntervals.activeClipIndices(at: time).map { clips[$0] }
        let frameEnd = time + frameDuration
        var textIndex = firstTextClipIndex(after: time)
        var appendedText = false
        while textIndex < textClipsByStart.count {
            let clip = textClipsByStart[textIndex]
            guard clip.timelineStart < frameEnd else { break }
            if clip.timelineStart + clip.duration > time,
                !active.contains(where: { $0.clipID == clip.clipID })
            {
                active.append(clip)
                appendedText = true
            }
            textIndex += 1
        }
        if appendedText {
            active.sort { $0.renderOrder < $1.renderOrder }
        }
        return active
    }

    private func firstTextClipIndex(after time: Double) -> Int {
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

}

enum PreviewQuality: Equatable {
    case interactive
    case balanced
    case full

    var maximumDimension: Double? {
        switch self {
        case .interactive: 960
        case .balanced: 960
        case .full: nil
        }
    }

    var renderQualityProfile: RenderQualityProfile {
        switch self {
        case .interactive: .interactive
        case .balanced: .balanced
        case .full: .export
        }
    }
}

struct PreparedPreview {
    let composition: AVMutableComposition
    let videoComposition: AVVideoComposition?
    let audioMix: AVAudioMix?
    let duration: Double
    let topologyWasRebuilt: Bool
}

/// A track-local audio update prepared away from the main actor.
///
/// The graph revision prevents an envelope that finished after a topology or
/// canonical mix rebuild from being installed into a newer player graph.
struct PreparedInteractiveAudioMix {
    let itemID: UUID
    let volume: AnimatableProperty<Double>
    let audioMix: AVAudioMix
    fileprivate let graphRevision: Int
}

private struct PreviewRenderGraph {
    let topology: PreviewTopology
    let rendered: RenderedComposition
    let renderDescriptors: [RenderClipDescriptor]
    let depthClips: [UUID: RenderClipDescriptor]

    init(topology: PreviewTopology, rendered: RenderedComposition, renderDescriptors: [RenderClipDescriptor]) {
        self.topology = topology
        self.rendered = rendered
        self.renderDescriptors = renderDescriptors
        depthClips = renderDescriptors.reduce(into: [:]) { result, clip in
            if !clip.depthAnalyses.isEmpty { result[clip.clipID] = clip }
        }
    }
}

/// Packs cuts from the same decoded source into a few composition tracks.
/// Adjacent cuts stay on separate tracks so AVFoundation can preroll them.
private final class PreviewVideoTrackPool {
    private struct Lane {
        let track: AVMutableCompositionTrack
        var end: CMTime
    }

    private var lanesByURL: [URL: [Lane]] = [:]

    func insert(
        _ range: CMTimeRange,
        from sourceTrack: AVAssetTrack,
        url: URL,
        at start: CMTime,
        prerollGap: CMTime,
        into composition: AVMutableComposition
    ) throws -> AVMutableCompositionTrack? {
        var lanes = lanesByURL[url, default: []]
        let end = CMTimeAdd(start, range.duration)
        if let index = lanes.firstIndex(where: { CMTimeCompare(CMTimeAdd($0.end, prerollGap), start) <= 0 }) {
            let track = lanes[index].track
            try track.insertTimeRange(range, of: sourceTrack, at: start)
            lanes[index].end = end
            lanesByURL[url] = lanes
            return track
        }
        guard let track = composition.addMutableTrack(withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        try track.insertTimeRange(range, of: sourceTrack, at: start)
        lanes.append(Lane(track: track, end: end))
        lanesByURL[url] = lanes
        return track
    }
}

private struct PreviewTopology: Equatable {
    let canvas: PreviewCanvasTopology
    let tracks: [PreviewTrackTopology]

    init(project: EditorProject) {
        canvas = PreviewCanvasTopology(
            width: project.renderSettings.width,
            height: project.renderSettings.height,
            frameRate: project.renderSettings.frameRate
        )
        tracks = project.tracks.map {
            PreviewTrackTopology(
                id: $0.id,
                kind: $0.kind,
                isMuted: $0.isMuted,
                items: $0.items.map { item in
                    let mediaID: MediaID?
                    let mediaType: ClipMediaType?
                    switch item {
                    case .media(let media):
                        mediaID = media.mediaID
                        mediaType = media.mediaType
                    case .shape(let shape):
                        mediaID = shape.mediaID
                        mediaType = .image
                    case .text, .caption, .adjustment, .compound:
                        mediaID = nil
                        mediaType = nil
                    }
                    return PreviewItemTopology(
                        id: item.id,
                        kind: item.kind,
                        mediaID: mediaID,
                        mediaType: mediaType,
                        mediaURL: mediaID.flatMap { project.mediaLibrary[$0]?.url },
                        timelineStart: item.timelineStart,
                        placementDuration: item.placementDuration,
                        sourceRange: item.sourceRange,
                        hasShape: {
                            if case .shape = item { return true }
                            return false
                        }(),
                        speedSignature: {
                            if case .media(let media) = item { return media.speedMap.topologySignature }
                            return 0
                        }(),
                        usesBackgroundRemoval: item.editableVisuals?.backgroundRemoval != nil,
                        backgroundRemovalArtifact: {
                            guard case .media(let media) = item,
                                media.visuals.backgroundRemoval != nil
                            else { return nil }
                            return project.mediaLibrary[media.mediaID]?.backgroundRemovalArtifact
                        }()
                    )
                }
            )
        }
    }
}

private struct PreviewCanvasTopology: Equatable {
    let width: Int
    let height: Int
    let frameRate: Int32
}

private struct PreviewTrackTopology: Equatable {
    let id: UUID
    let kind: TrackKind
    let isMuted: Bool
    let items: [PreviewItemTopology]
}

private struct PreviewItemTopology: Equatable {
    let id: UUID
    let kind: TimelineItemKind
    let mediaID: MediaID?
    let mediaType: ClipMediaType?
    let mediaURL: URL?
    let timelineStart: Double
    let placementDuration: Double
    let sourceRange: TimeRangeValue?
    let hasShape: Bool
    let speedSignature: UInt64
    let usesBackgroundRemoval: Bool
    let backgroundRemovalArtifact: BackgroundRemovalArtifact?
}

private struct RenderDescriptorCompilationInput: @unchecked Sendable {
    let project: EditorProject
    let visualTrackIDs: [UUID: CMPersistentTrackID]
    let sourceTransforms: [UUID: CGAffineTransform]
    let backgroundMaskTrackIDs: [UUID: CMPersistentTrackID]
    let backgroundMaskTransforms: [UUID: CGAffineTransform]
    let stillImageValidationCache: StillImageValidationCache
}

/// The render-facing projection of a typed timeline item. Keeping this value
/// local to the composition layer prevents the renderer from round-tripping
/// through the legacy `TimelineClip` compatibility model.
private struct TimelineVisualSource {
    let id: UUID
    let name: String
    let mediaID: MediaID
    let mediaType: ClipMediaType
    let timelineStart: Double
    let sourceRange: TimeRangeValue
    let timelineDuration: Double
    let speedMap: SpeedMap
    let pitchFollowsSpeed: Bool
    let visuals: TimelineItemVisuals
    let shape: ClipShape?

    init(_ item: MediaTimelineItem) {
        id = item.id
        name = item.name
        mediaID = item.mediaID
        mediaType = item.mediaType
        timelineStart = item.timelineStart
        sourceRange = item.sourceRange
        timelineDuration = item.timelineDuration
        speedMap = item.speedMap
        pitchFollowsSpeed = item.pitchFollowsSpeed
        visuals = item.visuals
        shape = nil
    }

    init(_ item: ShapeTimelineItem) {
        id = item.id
        name = item.name
        mediaID = item.mediaID
        mediaType = .image
        timelineStart = item.timelineStart
        sourceRange = item.sourceRange
        timelineDuration = item.sourceRange.duration
        speedMap = .constant
        pitchFollowsSpeed = false
        visuals = item.visuals
        shape = item.shape
    }
}

enum CompositionRenderError: LocalizedError {
    case backgroundRemovalUnavailable(String)
    case sourceUnavailable(clipName: String, url: URL?)
    case sourceUnreadable(clipName: String, reason: String)
    case visualTrackUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .backgroundRemovalUnavailable(let clipName):
            "Background removal for \"\(clipName)\" is incomplete. Retry it or disable Remove BG before exporting."
        case .sourceUnavailable(let clipName, let url):
            if let url {
                "The source for \"\(clipName)\" is missing at \(url.lastPathComponent). Relink it before exporting."
            } else {
                "The source for \"\(clipName)\" is missing. Relink it before exporting."
            }
        case .sourceUnreadable(let clipName, let reason):
            "The source for \"\(clipName)\" cannot be read: \(reason)"
        case .visualTrackUnavailable(let clipName):
            "The source for \"\(clipName)\" contains no renderable video track."
        }
    }
}

private enum BackgroundRemovalAvailabilityPolicy: Equatable {
    case required
    case omitUnavailable
}

private enum RenderSourceAvailabilityPolicy: Equatable {
    case required
    case omitUnavailable
}

private actor PreviewAudioEnvelopePreparer {
    func points(
        for volume: AnimatableProperty<Double>,
        duration: Double,
        frameRate: Int32
    ) -> [AudioEnvelopePoint] {
        AudioEnvelopeSampler.points(
            for: volume,
            duration: duration,
            frameRate: frameRate
        )
    }
}

/// Repeated cuts in one build use the same metadata snapshot. The shared
/// asset cache still checks file identity on the first access of each build.
private struct CompositionMediaLookup {
    let cache: MediaAssetCache
    private var assets: [URL: CachedMediaAsset] = [:]

    init(cache: MediaAssetCache) {
        self.cache = cache
    }

    mutating func metadata(for url: URL) async throws -> CachedMediaAsset {
        if let asset = assets[url] { return asset }
        let asset = try await cache.metadata(for: url)
        assets[url] = asset
        return asset
    }
}

/// Converts an editor project into AVFoundation preview/export assets.
final class CompositionRenderService {
    private let timescale: CMTimeScale = 600
    private let retimingTimescale: CMTimeScale = 60_000
    private let assetCache: MediaAssetCache
    private let previewProxyStore: PreviewProxyStore?
    private let reusesPreviewVideoTracks: Bool
    private let depthCacheDirectory: URL?
    private let stillImageValidationCache = StillImageValidationCache()
    private let previewAudioEnvelopePreparer = PreviewAudioEnvelopePreparer()
    let livePreviewState = LivePreviewRenderState()
    @MainActor private var previewGraph: PreviewRenderGraph?
    @MainActor private(set) var previewSupportsExactScrubbing = false
    @MainActor private var previewGraphRevision = 0
    @MainActor private var previewPreparationGeneration = 0

    init(
        assetCache: MediaAssetCache = .shared,
        previewProxyStore: PreviewProxyStore? = .shared,
        reusesPreviewVideoTracks: Bool = true,
        depthCacheDirectory: URL? = nil
    ) {
        self.assetCache = assetCache
        self.previewProxyStore = previewProxyStore
        self.reusesPreviewVideoTracks = reusesPreviewVideoTracks
        self.depthCacheDirectory = depthCacheDirectory
    }

    private static func prepareTopology(_ project: EditorProject) async -> PreviewTopology {
        PreviewTopology(project: project)
    }

    @MainActor
    func canApplyLiveDepth(in stack: EffectStack, to itemID: UUID) -> Bool {
        let descriptor = previewGraph?.depthClips[itemID]
        return stack.effects.allSatisfy { effect in
            !effect.isEnabled || effect.moduleID != .depthMap || descriptor?.hasPreparedDepth(for: effect) == true
        }
    }

    @MainActor
    func invalidatePreviewGraph() {
        livePreviewState.invalidateComposedFrames()
        previewSupportsExactScrubbing = false
        previewGraph = nil
        previewGraphRevision &+= 1
        previewPreparationGeneration &+= 1
    }

    @MainActor
    func preparePreview(
        for project: EditorProject,
        quality: PreviewQuality,
        invalidation: EditorInvalidation,
        renderSessionID: UUID = UUID(),
        displayPixelSize: CGSize? = nil
    ) async throws -> PreparedPreview? {
        if !invalidation.isEmpty { livePreviewState.invalidateComposedFrames() }
        previewPreparationGeneration &+= 1
        let preparationGeneration = previewPreparationGeneration
        let signpostID = OSSignpostID(log: compositionMetricsLog)
        os_signpost(
            .begin,
            log: compositionMetricsLog,
            name: "Prepare Preview",
            signpostID: signpostID,
            "tracks=%d invalidation=%d",
            project.tracks.count,
            invalidation.rawValue
        )
        defer {
            os_signpost(
                .end,
                log: compositionMetricsLog,
                name: "Prepare Preview",
                signpostID: signpostID
            )
        }
        let topology = await Self.prepareTopology(project)
        try Task.checkCancellation()
        guard preparationGeneration == previewPreparationGeneration else { throw CancellationError() }
        let renderSettings = previewRenderSettings(
            for: project,
            quality: quality,
            displayPixelSize: displayPixelSize
        )
        let requiresTopologyBuild =
            invalidation.contains(.compositionTopology)
            || previewGraph?.topology != topology

        if requiresTopologyBuild {
            os_signpost(
                .event,
                log: compositionMetricsLog,
                name: "Rebuild Preview Topology",
                signpostID: signpostID
            )
            let rendered = try await makeComposition(
                for: project,
                renderSettings: renderSettings,
                backgroundRemovalPolicy: .omitUnavailable,
                qualityProfile: quality.renderQualityProfile,
                failurePolicy: .skipUnavailableEffects,
                livePreviewState: livePreviewState,
                renderSessionID: renderSessionID,
                usesPreviewProxies: true,
                displayPixelSize: displayPixelSize
            )
            try Task.checkCancellation()
            guard preparationGeneration == previewPreparationGeneration else {
                throw CancellationError()
            }
            guard rendered.duration > 0 else {
                previewGraph = nil
                previewGraphRevision &+= 1
                return nil
            }
            let initialDescriptors =
                (rendered.videoComposition?.instructions.first
                    as? MotionaryVideoCompositionInstruction)?.clips
                ?? []
            if let previewProxyStore {
                let videoSegments = rendered.composition.tracks
                    .filter { $0.mediaType == .video && $0.trackID != rendered.videoClockTrackID }
                    .flatMap { $0.segments ?? [] }.filter { !$0.isEmpty }
                previewSupportsExactScrubbing = videoSegments.allSatisfy {
                    $0.sourceURL.map(previewProxyStore.contains) == true
                }
            } else {
                previewSupportsExactScrubbing = false
            }
            previewGraph = PreviewRenderGraph(
                topology: topology,
                rendered: rendered,
                renderDescriptors: initialDescriptors
            )
            previewGraphRevision &+= 1
            return PreparedPreview(
                composition: rendered.composition,
                videoComposition: rendered.videoComposition,
                audioMix: rendered.audioMix,
                duration: rendered.duration,
                topologyWasRebuilt: true
            )
        }

        guard let graph = previewGraph else { return nil }
        let descriptors: [RenderClipDescriptor]
        if invalidation.contains(.previewFrame) {
            let compiled = try await compileRenderDescriptors(
                project: project,
                visualTrackIDs: graph.rendered.visualTrackIDs,
                sourceTransforms: graph.rendered.sourceTransforms,
                backgroundMaskTrackIDs: graph.rendered.backgroundMaskTrackIDs,
                backgroundMaskTransforms: graph.rendered.backgroundMaskTransforms
            )
            descriptors = try await DepthBakeStore.prepare(compiled, projectDirectory: depthCacheDirectory)
        } else {
            descriptors = graph.renderDescriptors
        }
        try Task.checkCancellation()
        guard preparationGeneration == previewPreparationGeneration else {
            throw CancellationError()
        }
        let videoComposition =
            invalidation.contains(.previewFrame)
            ? makeVideoComposition(
                renderSettings: renderSettings,
                renderScale: CGFloat(renderSettings.width)
                    / CGFloat(max(project.renderSettings.width, 1)),
                vectorRenderScale: vectorRenderScale(
                    renderSettings: renderSettings,
                    projectSettings: project.renderSettings,
                    qualityProfile: quality.renderQualityProfile,
                    displayPixelSize: displayPixelSize
                ),
                clips: descriptors,
                sourceTrackIDs: sourceTrackIDs(
                    for: descriptors,
                    videoClockTrackID: graph.rendered.videoClockTrackID
                ),
                sourceTrackIDForFrameTiming: graph.rendered.videoClockTrackID
                    ?? sourceTrackIDs(
                        for: descriptors,
                        videoClockTrackID: graph.rendered.videoClockTrackID
                    ).first
                    ?? kCMPersistentTrackID_Invalid,
                duration: project.duration,
                qualityProfile: quality.renderQualityProfile,
                failurePolicy: .failOnUnavailableEffects,
                livePreviewState: livePreviewState,
                renderSessionID: renderSessionID
            )
            : graph.rendered.videoComposition
        let audioMix =
            invalidation.contains(.audioMix)
            ? makeAudioMix(
                project: project,
                composition: graph.rendered.composition,
                audioTrackIDs: graph.rendered.audioTrackIDs
            )
            : graph.rendered.audioMix

        previewGraph = PreviewRenderGraph(
            topology: topology,
            rendered: RenderedComposition(
                composition: graph.rendered.composition,
                videoComposition: videoComposition,
                audioMix: audioMix,
                duration: project.duration,
                hasVideo: graph.rendered.hasVideo,
                videoClockTrackID: graph.rendered.videoClockTrackID,
                visualTrackIDs: graph.rendered.visualTrackIDs,
                audioTrackIDs: graph.rendered.audioTrackIDs,
                sourceTransforms: graph.rendered.sourceTransforms,
                backgroundMaskTrackIDs: graph.rendered.backgroundMaskTrackIDs,
                backgroundMaskTransforms: graph.rendered.backgroundMaskTransforms
            ),
            renderDescriptors: descriptors
        )
        previewGraphRevision &+= 1
        return PreparedPreview(
            composition: graph.rendered.composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            duration: project.duration,
            topologyWasRebuilt: false
        )
    }

    func makeComposition(
        for project: EditorProject,
        renderSettings: RenderSettings? = nil
    ) async throws -> RenderedComposition {
        try await makeComposition(
            for: project,
            renderSettings: renderSettings ?? project.renderSettings,
            backgroundRemovalPolicy: .required,
            qualityProfile: .export,
            failurePolicy: .failOnUnavailableEffects
        )
    }

    func makePreviewBackgroundImage(
        for project: EditorProject,
        at time: Double,
        excluding itemID: UUID,
        displayPixelSize: CGSize? = nil
    ) async throws -> UIImage? {
        guard let item = project.item(id: itemID) else { return nil }
        var backgroundProject = project
        let hiddenItem: TimelineItem
        switch item {
        case .media(var media):
            media.visuals.transform.opacity = AnimatableProperty(baseValue: 0)
            hiddenItem = .media(media)
        case .shape(var shape):
            shape.visuals.transform.opacity = AnimatableProperty(baseValue: 0)
            hiddenItem = .shape(shape)
        case .text(var text):
            text.visuals.transform.opacity = AnimatableProperty(baseValue: 0)
            hiddenItem = .text(text)
        case .adjustment(var adjustment):
            adjustment.visuals.transform.opacity = AnimatableProperty(baseValue: 0)
            hiddenItem = .adjustment(adjustment)
        case .compound(var compound):
            compound.visuals.transform.opacity = AnimatableProperty(baseValue: 0)
            hiddenItem = .compound(compound)
        case .caption:
            return nil
        }
        backgroundProject.replaceItem(id: itemID, with: hiddenItem)

        let renderSettings = previewRenderSettings(
            for: project, quality: .balanced, displayPixelSize: displayPixelSize)
        let rendered = try await makeComposition(
            for: backgroundProject,
            renderSettings: renderSettings,
            backgroundRemovalPolicy: .omitUnavailable,
            qualityProfile: .balanced,
            failurePolicy: .skipUnavailableEffects,
            displayPixelSize: displayPixelSize
        )
        guard rendered.hasVideo, let videoComposition = rendered.videoComposition else {
            return nil
        }

        let frameDuration = 1 / Double(max(renderSettings.frameRate, 1))
        let frameTime = min(max(time, 0), max(rendered.duration - frameDuration, 0))
        let generator = AVAssetImageGenerator(asset: rendered.composition)
        generator.videoComposition = videoComposition
        generator.maximumSize = renderSettings.size
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(
            at: CMTime(seconds: frameTime, preferredTimescale: timescale)
        ).image
        return UIImage(cgImage: image)
    }

    func makePosterComposition(
        for project: EditorProject,
        renderSettings: RenderSettings,
        depthCacheDirectory: URL? = nil
    ) async throws -> RenderedComposition {
        try await makeComposition(
            for: project,
            renderSettings: renderSettings,
            backgroundRemovalPolicy: .omitUnavailable,
            qualityProfile: .balanced,
            failurePolicy: .skipUnavailableEffects,
            depthCacheDirectory: depthCacheDirectory
        )
    }

    private func makeComposition(
        for project: EditorProject,
        renderSettings: RenderSettings,
        backgroundRemovalPolicy: BackgroundRemovalAvailabilityPolicy,
        qualityProfile: RenderQualityProfile,
        failurePolicy: RenderFailurePolicy,
        livePreviewState: LivePreviewRenderState? = nil,
        renderSessionID: UUID = UUID(),
        usesPreviewProxies: Bool = false,
        displayPixelSize: CGSize? = nil,
        depthCacheDirectory: URL? = nil
    ) async throws -> RenderedComposition {
        let composition = AVMutableComposition()
        var mediaLookup = CompositionMediaLookup(cache: assetCache)
        var renderClips: [RenderClipDescriptor] = []
        var audioParameters: [AVAudioMixInputParameters] = []
        var visualTrackIDs: [UUID: CMPersistentTrackID] = [:]
        var audioTrackIDs: [UUID: CMPersistentTrackID] = [:]
        var sourceTransforms: [UUID: CGAffineTransform] = [:]
        var backgroundMaskTrackIDs: [UUID: CMPersistentTrackID] = [:]
        var backgroundMaskTransforms: [UUID: CGAffineTransform] = [:]
        var renderOrder = 0
        var videoClockTrackID: CMPersistentTrackID?

        let visualTracks = project.tracks.filter {
            ($0.kind == .visual || $0.kind == .shape || $0.kind == .text) && !$0.isMuted
        }
        for track in visualTracks.reversed() {
            try Task.checkCancellation()
            let previewVideoTracks = usesPreviewProxies && reusesPreviewVideoTracks ? PreviewVideoTrackPool() : nil
            for item in track.items.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                try Task.checkCancellation()
                switch item {
                case .media(let mediaItem):
                    guard mediaItem.sourceRange.duration > 0 else { continue }
                    try await insertVisualItem(
                        source: TimelineVisualSource(mediaItem),
                        project: project,
                        mediaLookup: &mediaLookup,
                        proxyStore: usesPreviewProxies ? previewProxyStore : nil,
                        previewVideoTracks: previewVideoTracks,
                        frameRate: renderSettings.frameRate,
                        composition: composition,
                        visualTrackIDs: &visualTrackIDs,
                        audioTrackIDs: &audioTrackIDs,
                        audioParameters: &audioParameters,
                        sourceTransforms: &sourceTransforms,
                        backgroundMaskTrackIDs: &backgroundMaskTrackIDs,
                        backgroundMaskTransforms: &backgroundMaskTransforms,
                        backgroundRemovalPolicy: backgroundRemovalPolicy,
                        sourceAvailabilityPolicy: failurePolicy == .failOnUnavailableEffects
                            ? .required : .omitUnavailable,
                        renderClips: &renderClips,
                        renderOrder: &renderOrder
                    )
                case .shape(let shapeItem):
                    guard shapeItem.sourceRange.duration > 0 else { continue }
                    try await insertVisualItem(
                        source: TimelineVisualSource(shapeItem),
                        project: project,
                        mediaLookup: &mediaLookup,
                        proxyStore: usesPreviewProxies ? previewProxyStore : nil,
                        frameRate: renderSettings.frameRate,
                        composition: composition,
                        visualTrackIDs: &visualTrackIDs,
                        audioTrackIDs: &audioTrackIDs,
                        audioParameters: &audioParameters,
                        sourceTransforms: &sourceTransforms,
                        backgroundMaskTrackIDs: &backgroundMaskTrackIDs,
                        backgroundMaskTransforms: &backgroundMaskTransforms,
                        backgroundRemovalPolicy: backgroundRemovalPolicy,
                        sourceAvailabilityPolicy: failurePolicy == .failOnUnavailableEffects
                            ? .required : .omitUnavailable,
                        renderClips: &renderClips,
                        renderOrder: &renderOrder
                    )
                case .text(let textItem):
                    renderClips.append(
                        RenderClipDescriptor(
                            trackID: kCMPersistentTrackID_Invalid,
                            backgroundMaskTrackID: nil,
                            clipID: textItem.id,
                            timelineStart: textItem.timelineStart,
                            duration: textItem.duration,
                            sourceTransform: .identity,
                            backgroundMaskSourceTransform: .identity,
                            transform: textItem.visuals.transform,
                            adjustments: textItem.visuals.adjustments,
                            effectStack: textItem.visuals.effectStack,
                            mask: textItem.visuals.mask,
                            backgroundRemoval: nil,
                            blendMode: textItem.visuals.blendMode,
                            blendIntensity: textItem.visuals.blendIntensity,
                            shape: nil,
                            text: textItem,
                            renderOrder: renderOrder
                        )
                    )
                    renderOrder += 1
                case .adjustment(let adjustmentItem):
                    renderClips.append(
                        RenderClipDescriptor(
                            trackID: kCMPersistentTrackID_Invalid,
                            backgroundMaskTrackID: nil,
                            clipID: adjustmentItem.id,
                            timelineStart: adjustmentItem.timelineStart,
                            duration: adjustmentItem.duration,
                            sourceTransform: .identity,
                            backgroundMaskSourceTransform: .identity,
                            transform: adjustmentItem.visuals.transform,
                            adjustments: adjustmentItem.visuals.adjustments,
                            effectStack: adjustmentItem.visuals.effectStack,
                            mask: adjustmentItem.visuals.mask,
                            backgroundRemoval: nil,
                            blendMode: adjustmentItem.visuals.blendMode,
                            blendIntensity: adjustmentItem.visuals.blendIntensity,
                            shape: nil,
                            text: nil,
                            role: .adjustment,
                            renderOrder: renderOrder
                        )
                    )
                    renderOrder += 1
                case .caption, .compound:
                    continue
                }
            }
        }

        for track in project.tracks where track.kind == .audio && !track.isMuted {
            try Task.checkCancellation()
            for item in track.items.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                try Task.checkCancellation()
                guard case .media(let mediaItem) = item,
                    mediaItem.mediaType == .audio,
                    mediaItem.sourceRange.duration > 0
                else { continue }
                guard let asset = project.mediaLibrary[mediaItem.mediaID] else {
                    if failurePolicy == .failOnUnavailableEffects {
                        throw CompositionRenderError.sourceUnavailable(
                            clipName: mediaItem.name,
                            url: nil
                        )
                    }
                    continue
                }
                if asset.url.isFileURL,
                    !FileManager.default.fileExists(atPath: asset.url.path)
                {
                    if failurePolicy == .failOnUnavailableEffects {
                        throw CompositionRenderError.sourceUnavailable(
                            clipName: mediaItem.name,
                            url: asset.url
                        )
                    }
                    continue
                }
                let metadata: CachedMediaAsset
                do {
                    metadata = try await mediaLookup.metadata(for: asset.url)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if failurePolicy == .failOnUnavailableEffects {
                        throw CompositionRenderError.sourceUnreadable(
                            clipName: mediaItem.name,
                            reason: error.localizedDescription
                        )
                    }
                    continue
                }
                try Task.checkCancellation()
                guard let sourceAudioTrack = metadata.audioTrack else {
                    if failurePolicy == .failOnUnavailableEffects {
                        throw CompositionRenderError.sourceUnreadable(
                            clipName: mediaItem.name,
                            reason: "No audio track was found."
                        )
                    }
                    continue
                }
                guard let compositionAudioTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                else {
                    if failurePolicy == .failOnUnavailableEffects {
                        throw CompositionRenderError.sourceUnreadable(
                            clipName: mediaItem.name,
                            reason: "AVFoundation could not create an audio composition track."
                        )
                    }
                    continue
                }
                audioTrackIDs[mediaItem.id] = compositionAudioTrack.trackID

                try insertRetimedTrack(
                    sourceTrack: sourceAudioTrack,
                    compositionTrack: compositionAudioTrack,
                    sourceRange: mediaItem.sourceRange,
                    timelineStart: mediaItem.timelineStart,
                    speedMap: mediaItem.speedMap
                )
                audioParameters.append(
                    makeAudioParameters(
                        track: compositionAudioTrack,
                        volume: mediaItem.visuals.volume,
                        timelineStart: mediaItem.timelineStart,
                        timelineDuration: mediaItem.timelineDuration,
                        pitchFollowsSpeed: mediaItem.pitchFollowsSpeed,
                        frameRate: renderSettings.frameRate
                    )
                )
            }
        }

        renderClips = Self.annotateLayerTargets(renderClips, project: project)
        let duration = max(project.duration, 0)
        // A clip is never a reliable project clock: it can end before audio,
        // another layer, or a gap. Keep frame requests running to project end.
        if duration > 0, !renderClips.isEmpty {
            videoClockTrackID = try await insertGeneratedVideoClock(
                duration: duration,
                frameRate: renderSettings.frameRate,
                composition: composition
            )
        }
        let videoSourceTrackIDs = sourceTrackIDs(
            for: renderClips,
            videoClockTrackID: videoClockTrackID
        )
        renderClips = try await DepthBakeStore.prepare(
            renderClips, projectDirectory: depthCacheDirectory ?? self.depthCacheDirectory
        )
        try Task.checkCancellation()
        let videoComposition = makeVideoComposition(
            renderSettings: renderSettings,
            renderScale: CGFloat(renderSettings.width)
                / CGFloat(max(project.renderSettings.width, 1)),
            vectorRenderScale: vectorRenderScale(
                renderSettings: renderSettings,
                projectSettings: project.renderSettings,
                qualityProfile: qualityProfile,
                displayPixelSize: displayPixelSize
            ),
            clips: renderClips,
            sourceTrackIDs: videoSourceTrackIDs,
            sourceTrackIDForFrameTiming: videoClockTrackID
                ?? videoSourceTrackIDs.first
                ?? kCMPersistentTrackID_Invalid,
            duration: duration,
            qualityProfile: qualityProfile,
            failurePolicy: livePreviewState == nil ? failurePolicy : .failOnUnavailableEffects,
            livePreviewState: livePreviewState,
            renderSessionID: renderSessionID
        )

        return RenderedComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: makeAudioMix(parameters: audioParameters),
            duration: duration,
            hasVideo: !renderClips.isEmpty,
            videoClockTrackID: videoClockTrackID,
            visualTrackIDs: visualTrackIDs,
            audioTrackIDs: audioTrackIDs,
            sourceTransforms: sourceTransforms,
            backgroundMaskTrackIDs: backgroundMaskTrackIDs,
            backgroundMaskTransforms: backgroundMaskTransforms
        )
    }

    private func makeVideoComposition(
        renderSettings: RenderSettings,
        renderScale: CGFloat,
        vectorRenderScale: CGFloat? = nil,
        clips: [RenderClipDescriptor],
        sourceTrackIDs: [CMPersistentTrackID],
        sourceTrackIDForFrameTiming: CMPersistentTrackID,
        duration: Double,
        qualityProfile: RenderQualityProfile,
        failurePolicy: RenderFailurePolicy,
        livePreviewState: LivePreviewRenderState? = nil,
        renderSessionID: UUID = UUID()
    ) -> AVVideoComposition? {
        guard !clips.isEmpty, duration > 0 else { return nil }
        guard sourceTrackIDForFrameTiming != kCMPersistentTrackID_Invalid else {
            return nil
        }

        let instruction = MotionaryVideoCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: cmTime(duration)),
            clips: clips,
            sourceTrackIDs: sourceTrackIDs,
            renderSize: renderSettings.size,
            renderScale: renderScale,
            vectorRenderScale: vectorRenderScale,
            backgroundColor: renderSettings.backgroundColor,
            frameDuration: 1 / Double(max(renderSettings.frameRate, 1)),
            qualityProfile: qualityProfile,
            failurePolicy: failurePolicy,
            livePreviewState: livePreviewState,
            renderSessionID: renderSessionID
        )
        let instructions: [MotionaryVideoCompositionInstruction]
        if clips.contains(where: {
            $0.trackID != kCMPersistentTrackID_Invalid
                || ($0.backgroundMaskTrackID ?? kCMPersistentTrackID_Invalid) != kCMPersistentTrackID_Invalid
        }) {
            instructions = decoderInstructions(
                template: instruction, duration: duration, clockID: sourceTrackIDForFrameTiming
            )
        } else {
            // Generated content only needs the clock. The renderer still
            // resolves every cut from the shared index at the actual frame time.
            instructions = [instruction]
        }
        if #available(iOS 26.0, *) {
            let configuration = AVVideoComposition.Configuration(
                animationTool: nil,
                colorPrimaries: nil,
                colorTransferFunction: nil,
                colorYCbCrMatrix: nil,
                customVideoCompositorClass: MotionaryVideoCompositor.self,
                frameDuration: CMTime(value: 1, timescale: renderSettings.frameRate),
                instructions: instructions,
                outputBufferDescription: nil,
                perFrameHDRDisplayMetadataPolicy: .propagate,
                renderScale: 1,
                renderSize: renderSettings.size,
                sourceSampleDataTrackIDs: [],
                sourceTrackIDForFrameTiming: sourceTrackIDForFrameTiming,
                spatialVideoConfigurations: []
            )
            return AVVideoComposition(configuration: configuration)
        }

        // The configuration initializer arrived in iOS 26. Build the same
        // composition through the native mutable API on earlier versions,
        // then return an immutable snapshot for preview and export.
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = MotionaryVideoCompositor.self
        composition.frameDuration = CMTime(value: 1, timescale: renderSettings.frameRate)
        composition.instructions = instructions
        composition.perFrameHDRDisplayMetadataPolicy = .propagate
        composition.renderScale = 1
        composition.renderSize = renderSettings.size
        composition.sourceSampleDataTrackIDs = []
        composition.sourceTrackIDForFrameTiming = sourceTrackIDForFrameTiming
        return composition.copy() as? AVVideoComposition
    }

    private func decoderInstructions(
        template: MotionaryVideoCompositionInstruction,
        duration: Double,
        clockID: CMPersistentTrackID
    ) -> [MotionaryVideoCompositionInstruction] {
        // Keep the original dependency lookup at each boundary, including
        // quantized cuts and gaps. Adjacent intervals with the same decoder
        // sources can share an instruction even if their visual layers differ.
        let boundaries = Array(Set(
            [CMTime.zero, cmTime(duration)] + template.clips.flatMap { clip in
                [cmTime(min(max(clip.timelineStart, 0), duration)),
                 cmTime(min(max(clip.timelineStart + clip.duration, 0), duration))]
            }
        )).sorted { CMTimeCompare($0, $1) < 0 }
        var instructions: [MotionaryVideoCompositionInstruction] = []
        var rangeStart = CMTime.zero
        var previousSources: [CMPersistentTrackID]?
        func appendRange(endingAt end: CMTime, sources: [CMPersistentTrackID]) {
            instructions.append(MotionaryVideoCompositionInstruction(
                timeRange: CMTimeRange(start: rangeStart, end: end), template: template, sourceTrackIDs: sources
            ))
        }
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            let midpoint = (CMTimeGetSeconds(start) + CMTimeGetSeconds(end)) / 2
            let active = template.clipIntervals.activeClipIndices(at: midpoint).map { template.clips[$0] }
            let sources = sourceTrackIDs(for: active, videoClockTrackID: clockID)
            if let previousSources, sources != previousSources {
                appendRange(endingAt: start, sources: previousSources)
                rangeStart = start
            }
            previousSources = sources
        }
        if let previousSources, let end = boundaries.last {
            appendRange(endingAt: end, sources: previousSources)
        }
        return instructions
    }

    private func sourceTrackIDs(
        for clips: [RenderClipDescriptor],
        videoClockTrackID: CMPersistentTrackID?
    ) -> [CMPersistentTrackID] {
        var result = clips
            .flatMap { clip in
                [clip.trackID, clip.backgroundMaskTrackID ?? kCMPersistentTrackID_Invalid]
            }
            .filter { $0 != kCMPersistentTrackID_Invalid }
        if let videoClockTrackID {
            result.append(videoClockTrackID)
        }
        return Array(Set(result)).sorted()
    }

    private func insertGeneratedVideoClock(
        duration: Double,
        frameRate: Int32,
        composition: AVMutableComposition
    ) async throws -> CMPersistentTrackID? {
        // A fixed, all-intra clock can repeat without encoding thousands of
        // invisible frames on project open, trimming or changing duration.
        let segmentDuration = CMTime(value: 4, timescale: 1)
        let url = try await MediaConversionHelper.blankVideoClockURL(
            duration: segmentDuration.seconds,
            frameRate: frameRate
        )
        try Task.checkCancellation()
        let metadata = try await assetCache.metadata(for: url)
        try Task.checkCancellation()
        guard let sourceTrack = metadata.videoTrack,
            let destinationTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else { return nil }
        let end = cmTime(duration)
        var cursor = CMTime.zero
        while cursor < end {
            try Task.checkCancellation()
            let length = min(segmentDuration, end - cursor)
            try destinationTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: length),
                of: sourceTrack,
                at: cursor
            )
            cursor = cursor + length
        }
        return destinationTrack.trackID
    }

    private func previewRenderSettings(
        for project: EditorProject,
        quality: PreviewQuality,
        displayPixelSize: CGSize? = nil
    ) -> RenderSettings {
        let settings = project.renderSettings
        guard let maximumDimension = quality.maximumDimension else { return settings }
        // Bind preview resolution to the physical preview surface. Rendering
        // past the surface only spends fill rate on upscaling the layer
        // afterwards, and rendering below the old 960 cap would soften text
        // the user can already see at display size. The effective cap is
        // therefore the smaller of the long-standing 960 budget and the
        // surface's pixel size. Export never reaches this helper.
        let effectiveMaximumDimension: Double
        if let displayPixelSize, displayPixelSize.width >= 2, displayPixelSize.height >= 2 {
            effectiveMaximumDimension = min(maximumDimension, max(Double(displayPixelSize.width), Double(displayPixelSize.height)))
        } else {
            effectiveMaximumDimension = maximumDimension
        }
        let width = Double(max(settings.width, 1))
        let height = Double(max(settings.height, 1))
        let scale = min(1, effectiveMaximumDimension / max(width, height))

        func evenDimension(_ value: Double) -> Int {
            let rounded = max(Int((value * scale).rounded()), 2)
            return rounded.isMultiple(of: 2) ? rounded : rounded - 1
        }

        return RenderSettings(
            width: evenDimension(width),
            height: evenDimension(height),
            frameRate: max(settings.frameRate, 1),
            backgroundColor: settings.backgroundColor
        )
    }

    private func vectorRenderScale(
        renderSettings: RenderSettings,
        projectSettings: RenderSettings,
        qualityProfile: RenderQualityProfile,
        displayPixelSize: CGSize? = nil
    ) -> CGFloat {
        let logicalScale = CGFloat(renderSettings.width)
            / CGFloat(max(projectSettings.width, 1))
        switch qualityProfile {
        case .export:
            return logicalScale
        case .interactive, .balanced:
            // A 1.5x supersampled vector proxy remains crisp on the preview
            // surface without forcing every text/shape project through a full
            // export-resolution frame graph. Never raster text/shape past the
            // physical surface either: the display downsamples excess pixels
            // for free, so cap the supersampling at the surface's own scale.
            let supersampled = min(max(logicalScale * 1.5, logicalScale), 1)
            guard let displayPixelSize, displayPixelSize.width >= 2, displayPixelSize.height >= 2 else {
                return supersampled
            }
            let displayScale = max(
                CGFloat(displayPixelSize.width) / CGFloat(max(projectSettings.width, 1)),
                CGFloat(displayPixelSize.height) / CGFloat(max(projectSettings.height, 1))
            )
            return min(supersampled, min(max(displayScale, logicalScale), 1))
        }
    }

    private func insertVisualItem(
        source: TimelineVisualSource,
        project: EditorProject,
        mediaLookup: inout CompositionMediaLookup,
        proxyStore: PreviewProxyStore? = nil,
        previewVideoTracks: PreviewVideoTrackPool? = nil,
        frameRate: Int32,
        composition: AVMutableComposition,
        visualTrackIDs: inout [UUID: CMPersistentTrackID],
        audioTrackIDs: inout [UUID: CMPersistentTrackID],
        audioParameters: inout [AVAudioMixInputParameters],
        sourceTransforms: inout [UUID: CGAffineTransform],
        backgroundMaskTrackIDs: inout [UUID: CMPersistentTrackID],
        backgroundMaskTransforms: inout [UUID: CGAffineTransform],
        backgroundRemovalPolicy: BackgroundRemovalAvailabilityPolicy,
        sourceAvailabilityPolicy: RenderSourceAvailabilityPolicy,
        renderClips: inout [RenderClipDescriptor],
        renderOrder: inout Int
    ) async throws {
        if let shape = source.shape {
            visualTrackIDs[source.id] = kCMPersistentTrackID_Invalid
            renderClips.append(
                RenderClipDescriptor(
                    trackID: kCMPersistentTrackID_Invalid,
                    backgroundMaskTrackID: nil,
                    clipID: source.id,
                    timelineStart: source.timelineStart,
                    duration: source.timelineDuration,
                    sourceTransform: .identity,
                    backgroundMaskSourceTransform: .identity,
                    transform: source.visuals.transform,
                    adjustments: source.visuals.adjustments,
                    effectStack: source.visuals.effectStack,
                    mask: source.visuals.mask,
                    backgroundRemoval: nil,
                    blendMode: source.visuals.blendMode,
                    blendIntensity: source.visuals.blendIntensity,
                    shape: shape,
                    text: nil,
                    renderOrder: renderOrder
                )
            )
            renderOrder += 1
            return
        }

        guard let mediaAsset = project.mediaLibrary[source.mediaID] else {
            if sourceAvailabilityPolicy == .required {
                throw CompositionRenderError.sourceUnavailable(
                    clipName: source.name,
                    url: nil
                )
            }
            return
        }
        if mediaAsset.url.isFileURL,
            !FileManager.default.fileExists(atPath: mediaAsset.url.path)
        {
            if sourceAvailabilityPolicy == .required {
                throw CompositionRenderError.sourceUnavailable(
                    clipName: source.name,
                    url: mediaAsset.url
                )
            }
            return
        }
        if source.mediaType == .image,
            let stillImageCacheIdentity = stillImageValidationCache.validatedIdentity(
                for: mediaAsset.url
            )
        {
            let settings = source.visuals.backgroundRemoval
            let artifact = mediaAsset.backgroundRemovalArtifact
            let maskURL = artifact.flatMap { artifact -> URL? in
                guard artifact.algorithmVersion == BackgroundRemovalArtifact.currentAlgorithmVersion,
                    artifact.url.pathExtension.lowercased() == "png",
                    FileManager.default.fileExists(atPath: artifact.url.path)
                else { return nil }
                return artifact.url
            }
            if settings?.requiresForegroundMatte == true, maskURL == nil,
                backgroundRemovalPolicy == .required {
                throw CompositionRenderError.backgroundRemovalUnavailable(source.name)
            }
            visualTrackIDs[source.id] = kCMPersistentTrackID_Invalid
            renderClips.append(
                RenderClipDescriptor(
                    trackID: kCMPersistentTrackID_Invalid,
                    backgroundMaskTrackID: nil,
                    backgroundMaskImageURL: maskURL,
                    stillImageURL: mediaAsset.url,
                    stillImageCacheIdentity: stillImageCacheIdentity,
                    clipID: source.id,
                    timelineStart: source.timelineStart,
                    duration: source.timelineDuration,
                    sourceTransform: .identity,
                    backgroundMaskSourceTransform: .identity,
                    transform: source.visuals.transform,
                    adjustments: source.visuals.adjustments,
                    effectStack: source.visuals.effectStack,
                    mask: source.visuals.mask,
                    backgroundRemoval: settings,
                    blendMode: source.visuals.blendMode,
                    blendIntensity: source.visuals.blendIntensity,
                    shape: nil,
                    text: nil,
                    renderOrder: renderOrder
                )
            )
            renderOrder += 1
            return
        }

        let metadata: CachedMediaAsset
        do {
            metadata = try await mediaLookup.metadata(for: mediaAsset.url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if sourceAvailabilityPolicy == .required {
                throw CompositionRenderError.sourceUnreadable(
                    clipName: source.name,
                    reason: error.localizedDescription
                )
            }
            return
        }
        try Task.checkCancellation()
        var videoMetadata = metadata
        var sourcePixelTransform = CGAffineTransform.identity
        if source.mediaType == .video, let proxyStore {
            do {
                if let proxy = try await proxyStore.availableProxy(source: metadata) {
                    videoMetadata = try await mediaLookup.metadata(for: proxy.url)
                    sourcePixelTransform = proxy.sourcePixelTransform
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLogger.rendering.warning("Preview proxy unavailable for \(source.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        try Task.checkCancellation()
        guard let sourceVideoTrack = videoMetadata.videoTrack else {
            if sourceAvailabilityPolicy == .required {
                throw CompositionRenderError.visualTrackUnavailable(source.name)
            }
            return
        }

        let destination: AVMutableCompositionTrack?
        let usesSharedTrack = previewVideoTracks != nil && source.mediaType == .video
            && !source.speedMap.hasVariableSpeed && source.speedMap.speed(at: 0) == 1
        if usesSharedTrack {
            destination = try previewVideoTracks?.insert(
                CMTimeRange(start: cmTime(source.sourceRange.start), duration: cmTime(source.sourceRange.duration)),
                from: sourceVideoTrack, url: videoMetadata.asset.url, at: cmTime(source.timelineStart),
                prerollGap: CMTime(value: 1, timescale: max(frameRate, 1)), into: composition
            )
        } else {
            destination = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }
        guard let compositionVideoTrack = destination else {
            if sourceAvailabilityPolicy == .required {
                throw CompositionRenderError.visualTrackUnavailable(source.name)
            }
            return
        }
        visualTrackIDs[source.id] = compositionVideoTrack.trackID

        if source.mediaType == .image {
            try insertLoopedLegacyStillVideo(
                sourceRange: source.sourceRange,
                timelineStart: source.timelineStart,
                originalDuration: mediaAsset.originalDuration,
                assetDuration: metadata.duration,
                sourceVideoTrack: sourceVideoTrack,
                compositionVideoTrack: compositionVideoTrack,
                frameRate: frameRate
            )
        } else if !usesSharedTrack {
            try insertRetimedTrack(
                sourceTrack: sourceVideoTrack,
                compositionTrack: compositionVideoTrack,
                sourceRange: source.sourceRange,
                timelineStart: source.timelineStart,
                speedMap: source.speedMap
            )
        }

        let sourceTransform = sourcePixelTransform.concatenating(VideoSourceGeometry.normalizedTransform(
            naturalSize: metadata.naturalSize ?? .zero,
            transform: metadata.preferredTransform
        ))
        sourceTransforms[source.id] = sourceTransform
        let visuals = source.visuals
        var backgroundMaskTrackID: CMPersistentTrackID?
        var backgroundMaskSourceTransform = CGAffineTransform.identity
        if source.shape == nil, visuals.backgroundRemoval?.requiresForegroundMatte == true {
            let artifact = mediaAsset.backgroundRemovalArtifact
            let artifactIsAvailable = artifact.map { artifact in
                artifact.algorithmVersion == BackgroundRemovalArtifact.currentAlgorithmVersion
                    && artifact.covers(source.sourceRange)
                    && FileManager.default.fileExists(atPath: artifact.url.path)
            } ?? false

            if !artifactIsAvailable, backgroundRemovalPolicy == .required {
                throw CompositionRenderError.backgroundRemovalUnavailable(source.name)
            }

            if artifactIsAvailable, let artifact {
                do {
                    let maskMetadata = try await mediaLookup.metadata(for: artifact.url)
                    try Task.checkCancellation()
                    guard let maskSourceTrack = maskMetadata.videoTrack,
                        let maskCompositionTrack = composition.addMutableTrack(
                            withMediaType: .video,
                            preferredTrackID: kCMPersistentTrackID_Invalid
                        )
                    else {
                        throw CompositionRenderError.backgroundRemovalUnavailable(source.name)
                    }
                    let maskSourceRange = TimeRangeValue(
                        start: max(source.sourceRange.start - artifact.sourceRange.start, 0),
                        duration: source.sourceRange.duration
                    )
                    try insertRetimedTrack(sourceTrack: maskSourceTrack,
                        compositionTrack: maskCompositionTrack, sourceRange: maskSourceRange,
                        timelineStart: source.timelineStart, speedMap: source.speedMap)
                    backgroundMaskTrackID = maskCompositionTrack.trackID
                    backgroundMaskTrackIDs[source.id] = maskCompositionTrack.trackID
                    backgroundMaskSourceTransform = VideoSourceGeometry.normalizedTransform(
                        naturalSize: maskMetadata.naturalSize ?? .zero,
                        transform: maskMetadata.preferredTransform
                    )
                    backgroundMaskTransforms[source.id] = backgroundMaskSourceTransform
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if backgroundRemovalPolicy == .required {
                        throw CompositionRenderError.backgroundRemovalUnavailable(source.name)
                    }
                }
            }
        }
        // The compositor must agree with AVFoundation's actual source-track
        // coverage at clip edges. Retiming and composition timescale rounding
        // can move those edges by a fraction of a frame from the model's raw
        // Double range, which otherwise schedules a source lookup with no
        // decoded buffer.
        let renderRange: CMTimeRange
        if usesSharedTrack {
            renderRange = CMTimeRange(
                start: cmTime(source.timelineStart),
                duration: cmTime(source.timelineDuration)
            )
        } else {
            // A composition track includes the empty edit preceding a clip
            // inserted after time zero. Its timeRange therefore describes the
            // whole track, not the interval containing decoded video.
            let populatedSegments = compositionVideoTrack.segments.filter { !$0.isEmpty }
            if let first = populatedSegments.first, let last = populatedSegments.last {
                renderRange = CMTimeRange(
                    start: first.timeMapping.target.start,
                    end: last.timeMapping.target.end
                )
            } else {
                renderRange = CMTimeRange(start: cmTime(source.timelineStart), duration: .zero)
            }
        }
        renderClips.append(
            RenderClipDescriptor(
                trackID: compositionVideoTrack.trackID,
                backgroundMaskTrackID: backgroundMaskTrackID,
                clipID: source.id,
                timelineStart: renderRange.start.seconds,
                duration: renderRange.duration.seconds,
                sourceTransform: sourceTransform,
                backgroundMaskSourceTransform: backgroundMaskSourceTransform,
                transform: visuals.transform,
                adjustments: visuals.adjustments,
                effectStack: visuals.effectStack,
                mask: visuals.mask,
                backgroundRemoval: visuals.backgroundRemoval,
                blendMode: visuals.blendMode,
                blendIntensity: visuals.blendIntensity,
                shape: source.shape,
                text: nil,
                renderOrder: renderOrder,
                temporalSource: source.mediaType == .video
                    ? EffectTemporalSource(
                        url: mediaAsset.url,
                        sourceStart: source.sourceRange.start,
                        sourceDuration: source.sourceRange.duration,
                        speedMap: source.speedMap,
                        backgroundMatteURL: mediaAsset.backgroundRemovalArtifact?.url
                    )
                    : nil
            )
        )
        renderOrder += 1

        let audioTracks = CompositionAudioPolicy.includesSourceAudio(for: source.mediaType)
            ? metadata.audioTrack.map { [$0] } ?? []
            : []
        if let sourceAudioTrack = audioTracks.first,
            let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        {
            audioTrackIDs[source.id] = compositionAudioTrack.trackID
            try insertRetimedTrack(
                sourceTrack: sourceAudioTrack,
                compositionTrack: compositionAudioTrack,
                sourceRange: source.sourceRange,
                timelineStart: source.timelineStart,
                speedMap: source.speedMap
            )
            audioParameters.append(
                makeAudioParameters(
                    track: compositionAudioTrack,
                    volume: visuals.volume,
                    timelineStart: source.timelineStart,
                    timelineDuration: source.timelineDuration,
                    pitchFollowsSpeed: source.pitchFollowsSpeed,
                    frameRate: frameRate
                )
            )
        }
    }

    private func insertRetimedTrack(
        sourceTrack: AVAssetTrack,
        compositionTrack: AVMutableCompositionTrack,
        sourceRange: TimeRangeValue,
        timelineStart: Double,
        speedMap: SpeedMap
    ) throws {
        if !speedMap.hasVariableSpeed {
            let sourceTimeRange = CMTimeRange(
                start: cmTime(sourceRange.start),
                duration: cmTime(sourceRange.duration)
            )
            try compositionTrack.insertTimeRange(
                sourceTimeRange,
                of: sourceTrack,
                at: cmTime(timelineStart)
            )
            let timelineDuration = speedMap.timelineDuration(
                sourceDuration: sourceRange.duration
            )
            if abs(sourceRange.duration - timelineDuration) > 0.001 {
                compositionTrack.scaleTimeRange(
                    CMTimeRange(
                        start: cmTime(timelineStart),
                        duration: cmTime(sourceRange.duration)
                    ),
                    toDuration: cmTime(timelineDuration)
                )
            }
            return
        }

        let sourceTimeRange = CMTimeRange(
            start: retimingTime(sourceRange.start),
            duration: retimingTime(sourceRange.duration)
        )
        try compositionTrack.insertTimeRange(
            sourceTimeRange,
            of: sourceTrack,
            at: retimingTime(timelineStart)
        )

        // Scale an already contiguous edit from the end towards the start. Inserting
        // separately scaled source ranges can leave sub-frame gaps at their joins;
        // the custom compositor then receives no source frame and renders black.
        for segment in speedMap.renderSegments(sourceDuration: sourceRange.duration).reversed() {
            if abs(segment.sourceDuration - segment.timelineDuration) > 0.000_5 {
                compositionTrack.scaleTimeRange(
                    CMTimeRange(
                        start: retimingTime(timelineStart + segment.sourceStart),
                        duration: retimingTime(segment.sourceDuration)
                    ),
                    toDuration: retimingTime(segment.timelineDuration)
                )
            }
        }
    }

    /// Schema-10 image assets were stored as one-frame JPEG movies. Keep that
    /// source format readable while all newly imported stills stay as images.
    private func insertLoopedLegacyStillVideo(
        sourceRange: TimeRangeValue,
        timelineStart: Double,
        originalDuration: Double,
        assetDuration: Double,
        sourceVideoTrack: AVAssetTrack,
        compositionVideoTrack: AVMutableCompositionTrack,
        frameRate: Int32
    ) throws {
        let minimumSegmentDuration = 1 / Double(max(frameRate, 1))
        let loopDuration = max(
            min(
                assetDuration.isFinite ? assetDuration : originalDuration,
                originalDuration > 0 ? originalDuration : Double.greatestFiniteMagnitude
            ),
            minimumSegmentDuration
        )
        var remainingDuration = max(sourceRange.duration, 0)
        var timelineCursor = timelineStart

        while remainingDuration > 0.0005 {
            let segmentDuration = min(loopDuration, remainingDuration)
            let segment = CMTimeRange(start: .zero, duration: cmTime(segmentDuration))
            try compositionVideoTrack.insertTimeRange(
                segment,
                of: sourceVideoTrack,
                at: cmTime(timelineCursor)
            )
            timelineCursor += segmentDuration
            remainingDuration -= segmentDuration
        }
    }

    private func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    private func retimingTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: retimingTimescale)
    }

    private func makeAudioParameters(
        track: AVCompositionTrack,
        volume: AnimatableProperty<Double>,
        timelineStart: Double,
        timelineDuration: Double,
        pitchFollowsSpeed: Bool = false,
        frameRate: Int32
    ) -> AVAudioMixInputParameters {
        let points = AudioEnvelopeSampler.points(
            for: volume,
            duration: timelineDuration,
            frameRate: frameRate
        )
        return makeAudioParameters(
            track: track,
            volume: volume,
            timelineStart: timelineStart,
            pitchFollowsSpeed: pitchFollowsSpeed,
            points: points
        )
    }

    private func makeAudioParameters(
        track: AVCompositionTrack,
        volume: AnimatableProperty<Double>,
        timelineStart: Double,
        pitchFollowsSpeed: Bool,
        points: [AudioEnvelopePoint]
    ) -> AVAudioMixInputParameters {
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTimePitchAlgorithm = pitchFollowsSpeed ? .varispeed : .timeDomain
        guard !points.isEmpty else {
            parameters.setVolume(Float(volume.baseValue), at: cmTime(timelineStart))
            return parameters
        }

        for command in AudioEnvelopeSampler.commands(from: points) {
            switch command {
            case .set(let time, let value):
                parameters.setVolume(
                    Float(value),
                    at: cmTime(timelineStart + time)
                )
            case .ramp(let startTime, let duration, let startValue, let endValue):
                parameters.setVolumeRamp(
                    fromStartVolume: Float(startValue),
                    toEndVolume: Float(endValue),
                    timeRange: CMTimeRange(
                        start: cmTime(timelineStart + startTime),
                        duration: cmTime(duration)
                    )
                )
            }
        }
        return parameters
    }

    private func makeAudioMix(parameters: [AVAudioMixInputParameters]) -> AVAudioMix? {
        guard !parameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    private func compileRenderDescriptors(
        project: EditorProject,
        visualTrackIDs: [UUID: CMPersistentTrackID],
        sourceTransforms: [UUID: CGAffineTransform],
        backgroundMaskTrackIDs: [UUID: CMPersistentTrackID],
        backgroundMaskTransforms: [UUID: CGAffineTransform]
    ) async throws -> [RenderClipDescriptor] {
        let input = RenderDescriptorCompilationInput(
            project: project,
            visualTrackIDs: visualTrackIDs,
            sourceTransforms: sourceTransforms,
            backgroundMaskTrackIDs: backgroundMaskTrackIDs,
            backgroundMaskTransforms: backgroundMaskTransforms,
            stillImageValidationCache: stillImageValidationCache
        )
        let compilationTask = Task.detached(priority: .userInitiated) {
            let signpostID = OSSignpostID(log: compositionMetricsLog)
            os_signpost(
                .begin,
                log: compositionMetricsLog,
                name: "Compile Render Descriptors",
                signpostID: signpostID,
                "tracks=%d",
                input.project.tracks.count
            )
            defer {
                os_signpost(
                    .end,
                    log: compositionMetricsLog,
                    name: "Compile Render Descriptors",
                    signpostID: signpostID
                )
            }
            return try Self.compileRenderDescriptors(input)
        }
        return try await withTaskCancellationHandler {
            try await compilationTask.value
        } onCancel: {
            compilationTask.cancel()
        }
    }

    private static func compileRenderDescriptors(
        _ input: RenderDescriptorCompilationInput
    ) throws -> [RenderClipDescriptor] {
        let project = input.project
        let visualTrackIDs = input.visualTrackIDs
        let sourceTransforms = input.sourceTransforms
        let backgroundMaskTrackIDs = input.backgroundMaskTrackIDs
        let backgroundMaskTransforms = input.backgroundMaskTransforms
        var descriptors: [RenderClipDescriptor] = []
        var renderOrder = 0
        let visualTracks = project.tracks.filter {
            ($0.kind == .visual || $0.kind == .shape || $0.kind == .text) && !$0.isMuted
        }
        for track in visualTracks.reversed() {
            try Task.checkCancellation()
            for item in track.items.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                try Task.checkCancellation()
                switch item {
                case .media(let mediaItem):
                    guard let trackID = visualTrackIDs[mediaItem.id]
                    else { continue }
                    let visuals = mediaItem.visuals
                    let stillImageURL: URL?
                    let stillImageCacheIdentity: String?
                    if mediaItem.mediaType == .image,
                        let asset = project.mediaLibrary[mediaItem.mediaID],
                        let identity = input.stillImageValidationCache.validatedIdentity(
                            for: asset.url
                        )
                    {
                        stillImageURL = asset.url
                        stillImageCacheIdentity = identity
                    } else {
                        stillImageURL = nil
                        stillImageCacheIdentity = nil
                    }
                    descriptors.append(
                        RenderClipDescriptor(
                            trackID: trackID,
                            backgroundMaskTrackID: backgroundMaskTrackIDs[mediaItem.id],
                            backgroundMaskImageURL: stillImageURL == nil ? nil
                                : project.mediaLibrary[mediaItem.mediaID]?.backgroundRemovalArtifact?.url,
                            stillImageURL: stillImageURL,
                            stillImageCacheIdentity: stillImageCacheIdentity,
                            clipID: mediaItem.id,
                            timelineStart: mediaItem.timelineStart,
                            duration: mediaItem.timelineDuration,
                            sourceTransform: sourceTransforms[mediaItem.id] ?? .identity,
                            backgroundMaskSourceTransform: backgroundMaskTransforms[mediaItem.id] ?? .identity,
                            transform: visuals.transform,
                            adjustments: visuals.adjustments,
                            effectStack: visuals.effectStack,
                            mask: visuals.mask,
                            backgroundRemoval: visuals.backgroundRemoval,
                            blendMode: visuals.blendMode,
                            blendIntensity: visuals.blendIntensity,
                            shape: nil,
                            text: nil,
                            renderOrder: renderOrder,
                            temporalSource: mediaItem.mediaType == .video
                                ? project.mediaLibrary[mediaItem.mediaID].map {
                                    EffectTemporalSource(url: $0.url, sourceStart: mediaItem.sourceRange.start,
                                        sourceDuration: mediaItem.sourceRange.duration, speedMap: mediaItem.speedMap,
                                        backgroundMatteURL: $0.backgroundRemovalArtifact?.url)
                                } : nil
                        )
                    )
                    renderOrder += 1
                case .shape(let shapeItem):
                    guard let trackID = visualTrackIDs[shapeItem.id]
                    else { continue }
                    let visuals = shapeItem.visuals
                    descriptors.append(
                        RenderClipDescriptor(
                            trackID: trackID,
                            backgroundMaskTrackID: nil,
                            clipID: shapeItem.id,
                            timelineStart: shapeItem.timelineStart,
                            duration: shapeItem.sourceRange.duration,
                            sourceTransform: sourceTransforms[shapeItem.id] ?? .identity,
                            backgroundMaskSourceTransform: .identity,
                            transform: visuals.transform,
                            adjustments: visuals.adjustments,
                            effectStack: visuals.effectStack,
                            mask: visuals.mask,
                            backgroundRemoval: nil,
                            blendMode: visuals.blendMode,
                            blendIntensity: visuals.blendIntensity,
                            shape: shapeItem.shape,
                            text: nil,
                            renderOrder: renderOrder
                        )
                    )
                    renderOrder += 1
                case .text(let textItem):
                    descriptors.append(
                        RenderClipDescriptor(
                            trackID: kCMPersistentTrackID_Invalid,
                            backgroundMaskTrackID: nil,
                            clipID: textItem.id,
                            timelineStart: textItem.timelineStart,
                            duration: textItem.duration,
                            sourceTransform: .identity,
                            backgroundMaskSourceTransform: .identity,
                            transform: textItem.visuals.transform,
                            adjustments: textItem.visuals.adjustments,
                            effectStack: textItem.visuals.effectStack,
                            mask: textItem.visuals.mask,
                            backgroundRemoval: nil,
                            blendMode: textItem.visuals.blendMode,
                            blendIntensity: textItem.visuals.blendIntensity,
                            shape: nil,
                            text: textItem,
                            renderOrder: renderOrder
                        )
                    )
                    renderOrder += 1
                case .adjustment(let adjustmentItem):
                    descriptors.append(
                        RenderClipDescriptor(
                            trackID: kCMPersistentTrackID_Invalid,
                            backgroundMaskTrackID: nil,
                            clipID: adjustmentItem.id,
                            timelineStart: adjustmentItem.timelineStart,
                            duration: adjustmentItem.duration,
                            sourceTransform: .identity,
                            backgroundMaskSourceTransform: .identity,
                            transform: adjustmentItem.visuals.transform,
                            adjustments: adjustmentItem.visuals.adjustments,
                            effectStack: adjustmentItem.visuals.effectStack,
                            mask: adjustmentItem.visuals.mask,
                            backgroundRemoval: nil,
                            blendMode: adjustmentItem.visuals.blendMode,
                            blendIntensity: adjustmentItem.visuals.blendIntensity,
                            shape: nil,
                            text: nil,
                            role: .adjustment,
                            renderOrder: renderOrder
                        )
                    )
                    renderOrder += 1
                case .caption, .compound:
                    continue
                }
            }
        }
        return annotateLayerTargets(descriptors, project: project)
    }

    private static func annotateLayerTargets(
        _ descriptors: [RenderClipDescriptor], project: EditorProject
    ) -> [RenderClipDescriptor] {
        var layers: [UUID: UUID] = [:]
        var targets: [UUID: AdjustmentLayerTargets] = [:]
        for track in project.tracks {
            for item in track.items {
                layers[item.id] = track.id
                if case .adjustment(let adjustment) = item {
                    targets[item.id] = adjustment.targets
                }
            }
        }
        return descriptors.map { descriptor in
            var descriptor = descriptor
            descriptor.layerID = layers[descriptor.clipID]
            descriptor.adjustmentTargets = targets[descriptor.clipID] ?? AdjustmentLayerTargets()
            return descriptor
        }
    }

    /// Returns whether the retained preview graph can accept a track-local
    /// audio update. Pure volume/keyframe interaction must not rebuild the
    /// composition topology or walk every project item.
    @MainActor
    func canPrepareInteractiveAudioMix(for itemID: UUID) -> Bool {
        previewGraph?.rendered.audioTrackIDs[itemID] != nil
    }

    /// Builds one selected track's volume envelope off the main actor and
    /// reuses every unaffected AVAudioMixInputParameters instance.
    ///
    /// This method deliberately does not mutate the retained graph. Call
    /// `installInteractiveAudioMix(_:)` only after verifying that the editor
    /// model still contains the captured volume property.
    @MainActor
    func prepareInteractiveAudioMix(
        for project: EditorProject,
        itemID: UUID
    ) async -> PreparedInteractiveAudioMix? {
        guard let graph = previewGraph,
            case .media(let mediaItem)? = project.item(id: itemID),
            let trackID = graph.rendered.audioTrackIDs[itemID],
            let track = graph.rendered.composition.track(withTrackID: trackID)
        else { return nil }

        let graphRevision = previewGraphRevision
        let volume = mediaItem.visuals.volume
        let signpostID = OSSignpostID(log: compositionMetricsLog)
        os_signpost(
            .begin,
            log: compositionMetricsLog,
            name: "Prepare Live Audio Envelope",
            signpostID: signpostID,
            "keyframes=%d",
            volume.keyframes.count
        )
        let points = await previewAudioEnvelopePreparer.points(
            for: volume,
            duration: mediaItem.timelineDuration,
            frameRate: project.renderSettings.frameRate
        )
        os_signpost(
            .end,
            log: compositionMetricsLog,
            name: "Prepare Live Audio Envelope",
            signpostID: signpostID,
            "points=%d",
            points.count
        )
        guard !Task.isCancelled,
            graphRevision == previewGraphRevision,
            previewGraph?.rendered.composition === graph.rendered.composition
        else { return nil }

        let updatedParameters = makeAudioParameters(
            track: track,
            volume: volume,
            timelineStart: mediaItem.timelineStart,
            pitchFollowsSpeed: mediaItem.pitchFollowsSpeed,
            points: points
        )
        var replacedSelectedTrack = false
        var parameters: [AVAudioMixInputParameters] =
            graph.rendered.audioMix?.inputParameters.map {
                parameters -> AVAudioMixInputParameters in
                guard parameters.trackID == trackID else { return parameters }
                replacedSelectedTrack = true
                return updatedParameters
            } ?? []
        if !replacedSelectedTrack {
            parameters.append(updatedParameters)
        }
        guard let audioMix = makeAudioMix(parameters: parameters) else { return nil }
        return PreparedInteractiveAudioMix(
            itemID: itemID,
            volume: volume,
            audioMix: audioMix,
            graphRevision: graphRevision
        )
    }

    /// Atomically promotes a prepared track-local mix into the retained
    /// preview graph. A stale result is rejected rather than overwriting a
    /// newer topology, commit, or live audio update.
    @MainActor
    func installInteractiveAudioMix(_ prepared: PreparedInteractiveAudioMix) -> Bool {
        guard prepared.graphRevision == previewGraphRevision,
            let graph = previewGraph,
            graph.rendered.audioTrackIDs[prepared.itemID] != nil
        else { return false }

        previewGraph = PreviewRenderGraph(
            topology: graph.topology,
            rendered: RenderedComposition(
                composition: graph.rendered.composition,
                videoComposition: graph.rendered.videoComposition,
                audioMix: prepared.audioMix,
                duration: graph.rendered.duration,
                hasVideo: graph.rendered.hasVideo,
                videoClockTrackID: graph.rendered.videoClockTrackID,
                visualTrackIDs: graph.rendered.visualTrackIDs,
                audioTrackIDs: graph.rendered.audioTrackIDs,
                sourceTransforms: graph.rendered.sourceTransforms,
                backgroundMaskTrackIDs: graph.rendered.backgroundMaskTrackIDs,
                backgroundMaskTransforms: graph.rendered.backgroundMaskTransforms
            ),
            renderDescriptors: graph.renderDescriptors
        )
        previewGraphRevision &+= 1
        os_signpost(
            .event,
            log: compositionMetricsLog,
            name: "Install Live Audio Mix"
        )
        return true
    }

    private func makeAudioMix(
        project: EditorProject,
        composition: AVMutableComposition,
        audioTrackIDs: [UUID: CMPersistentTrackID]
    ) -> AVAudioMix? {
        let parameters = project.tracks
            .filter { !$0.isMuted }
            .flatMap(\.items)
            .compactMap { item -> AVAudioMixInputParameters? in
                guard case .media(let mediaItem) = item,
                    let trackID = audioTrackIDs[mediaItem.id],
                    let track = composition.track(withTrackID: trackID)
                else { return nil }
                return makeAudioParameters(
                    track: track,
                    volume: mediaItem.visuals.volume,
                    timelineStart: mediaItem.timelineStart,
                    timelineDuration: mediaItem.timelineDuration,
                    pitchFollowsSpeed: mediaItem.pitchFollowsSpeed,
                    frameRate: project.renderSettings.frameRate
                )
            }
        return makeAudioMix(parameters: parameters)
    }
}

enum AudioEnvelopeTransition: Equatable, Sendable {
    /// Interpolate linearly from the preceding sampled point.
    case ramp
    /// Keep the preceding value constant, then switch at this point's time.
    case step
}

struct AudioEnvelopePoint: Equatable, Sendable {
    var time: Double
    var value: Double
    var transitionFromPrevious: AudioEnvelopeTransition = .ramp
}

enum AudioEnvelopeCommand: Equatable, Sendable {
    case set(time: Double, value: Double)
    case ramp(
        startTime: Double,
        duration: Double,
        startValue: Double,
        endValue: Double
    )
}

enum AudioEnvelopeSampler {
    private struct Boundary {
        var time: Double
        var transitionAfter: AudioEnvelopeTransition?
    }

    static func points(
        for property: AnimatableProperty<Double>,
        duration: Double,
        frameRate: Int32,
        tolerance: Double = 0.003
    ) -> [AudioEnvelopePoint] {
        let safeDuration = max(duration, 0)
        guard safeDuration > 0 else {
            return [AudioEnvelopePoint(time: 0, value: property.value(at: 0))]
        }

        let boundaries = (
            [
                Boundary(time: 0, transitionAfter: nil),
                Boundary(time: safeDuration, transitionAfter: nil),
            ]
            + property.keyframes.map { keyframe in
                Boundary(
                    time: min(max(keyframe.time, 0), safeDuration),
                    transitionAfter: {
                        if case .hold = keyframe.interpolation {
                            return .step
                        }
                        return .ramp
                    }()
                )
            }
        )
            .sorted { $0.time < $1.time }
            .reduce(into: [Boundary]()) { values, boundary in
                if let last = values.last,
                    abs(last.time - boundary.time) <= 0.000_001
                {
                    if let transitionAfter = boundary.transitionAfter {
                        values[values.count - 1].transitionAfter = transitionAfter
                    }
                } else {
                    values.append(boundary)
                }
            }
        let minimumInterval = 0.25 / Double(max(frameRate, 1))
        var result: [AudioEnvelopePoint] = []

        for pair in zip(boundaries, boundaries.dropFirst()) {
            if pair.0.transitionAfter == .step {
                append(
                    AudioEnvelopePoint(
                        time: pair.0.time,
                        value: property.value(at: pair.0.time)
                    ),
                    to: &result
                )
                append(
                    AudioEnvelopePoint(
                        time: pair.1.time,
                        value: property.value(at: pair.1.time),
                        transitionFromPrevious: .step
                    ),
                    to: &result
                )
                continue
            }
            appendAdaptiveSegment(
                property: property,
                start: pair.0.time,
                end: pair.1.time,
                tolerance: tolerance,
                minimumInterval: minimumInterval,
                depth: 0,
                result: &result
            )
        }

        if result.isEmpty {
            result.append(AudioEnvelopePoint(time: 0, value: property.value(at: 0)))
            result.append(AudioEnvelopePoint(time: safeDuration, value: property.value(at: safeDuration)))
        }
        return result
    }

    /// Converts sampled points into the exact AVAudioMix automation operations
    /// consumed by `makeAudioParameters`. Hold transitions become one
    /// instantaneous set command at the right boundary, never a dense series
    /// of approximation ramps.
    static func commands(from points: [AudioEnvelopePoint]) -> [AudioEnvelopeCommand] {
        guard let first = points.first else { return [] }
        var commands: [AudioEnvelopeCommand] = [
            .set(time: first.time, value: first.value)
        ]
        commands.reserveCapacity(points.count)
        for pair in zip(points, points.dropFirst()) {
            let start = pair.0
            let end = pair.1
            let duration = end.time - start.time
            if end.transitionFromPrevious == .step || duration <= 0.000_001 {
                commands.append(.set(time: end.time, value: end.value))
            } else {
                commands.append(
                    .ramp(
                        startTime: start.time,
                        duration: duration,
                        startValue: start.value,
                        endValue: end.value
                    )
                )
            }
        }
        return commands
    }

    private static func appendAdaptiveSegment(
        property: AnimatableProperty<Double>,
        start: Double,
        end: Double,
        tolerance: Double,
        minimumInterval: Double,
        depth: Int,
        result: inout [AudioEnvelopePoint]
    ) {
        let startValue = property.value(at: start)
        let endValue = property.value(at: end)
        append(AudioEnvelopePoint(time: start, value: startValue), to: &result)

        let quarter = start + (end - start) * 0.25
        let midpoint = (start + end) * 0.5
        let threeQuarter = start + (end - start) * 0.75
        let errors = [
            abs(property.value(at: quarter) - (startValue + (endValue - startValue) * 0.25)),
            abs(property.value(at: midpoint) - (startValue + (endValue - startValue) * 0.5)),
            abs(property.value(at: threeQuarter) - (startValue + (endValue - startValue) * 0.75))
        ]
        if depth < 12,
            end - start > minimumInterval,
            (errors.max() ?? 0) > tolerance
        {
            appendAdaptiveSegment(
                property: property,
                start: start,
                end: midpoint,
                tolerance: tolerance,
                minimumInterval: minimumInterval,
                depth: depth + 1,
                result: &result
            )
            appendAdaptiveSegment(
                property: property,
                start: midpoint,
                end: end,
                tolerance: tolerance,
                minimumInterval: minimumInterval,
                depth: depth + 1,
                result: &result
            )
        } else {
            append(AudioEnvelopePoint(time: end, value: endValue), to: &result)
        }
    }

    private static func append(_ point: AudioEnvelopePoint, to result: inout [AudioEnvelopePoint]) {
        if let last = result.last, abs(last.time - point.time) <= 0.000_001 {
            // The duplicate is the next segment's left boundary. Preserve the
            // transition that arrived at this time from the preceding segment;
            // replacing it would turn an exact hold step back into a ramp.
            let incomingTransition = last.transitionFromPrevious
            result[result.count - 1] = point
            result[result.count - 1].transitionFromPrevious = incomingTransition
        } else {
            result.append(point)
        }
    }
}
