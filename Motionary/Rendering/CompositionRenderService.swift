// AVFoundation composition construction shared by preview and export.

@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import UIKit

enum VideoSourceGeometry {
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

/// Per-clip information consumed by the custom video compositor.
struct RenderClipDescriptor: @unchecked Sendable {
    let trackID: CMPersistentTrackID
    let backgroundMaskTrackID: CMPersistentTrackID?
    /// Non-video visual sources are decoded once by the frame engine and use
    /// the shared composition clock instead of a synthetic per-item movie.
    let stillImageURL: URL?
    let clipID: UUID
    let timelineStart: Double
    let duration: Double
    let sourceTransform: CGAffineTransform
    let backgroundMaskSourceTransform: CGAffineTransform
    let transform: ClipTransform
    let adjustments: AdjustmentSettings
    let effectStack: EffectStack
    let mask: ItemMask?
    let backgroundRemoval: BackgroundRemovalSettings?
    let blendMode: BlendMode
    let blendIntensity: Double
    let shape: ClipShape?
    let text: TextTimelineItem?
    let renderOrder: Int

    init(
        trackID: CMPersistentTrackID,
        backgroundMaskTrackID: CMPersistentTrackID?,
        stillImageURL: URL? = nil,
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
        renderOrder: Int
    ) {
        self.trackID = trackID
        self.backgroundMaskTrackID = backgroundMaskTrackID
        self.stillImageURL = stillImageURL
        self.clipID = clipID
        self.timelineStart = timelineStart
        self.duration = duration
        self.sourceTransform = sourceTransform
        self.backgroundMaskSourceTransform = backgroundMaskSourceTransform
        self.transform = transform
        self.adjustments = adjustments
        self.effectStack = effectStack
        self.mask = mask
        self.backgroundRemoval = backgroundRemoval
        self.blendMode = blendMode
        self.blendIntensity = blendIntensity
        self.shape = shape
        self.text = text
        self.renderOrder = renderOrder
    }
}

struct RenderClipInterval: @unchecked Sendable {
    let start: Double
    let end: Double
    let clips: [RenderClipDescriptor]
}

/// Video composition instruction containing all clips active in a render interval.
final class MotionaryVideoCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let clips: [RenderClipDescriptor]
    let clipIntervals: [RenderClipInterval]
    let renderSize: CGSize
    let renderScale: CGFloat
    let vectorRenderScale: CGFloat
    let viewport: RenderViewport
    let backgroundColor: RGBAColor
    let frameDuration: Double
    let qualityProfile: RenderQualityProfile
    let failurePolicy: RenderFailurePolicy
    let livePreviewState: LivePreviewRenderState?

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
        livePreviewState: LivePreviewRenderState? = nil
    ) {
        self.timeRange = timeRange
        self.clips = clips.sorted { $0.renderOrder < $1.renderOrder }
        self.clipIntervals = Self.makeIntervals(clips: self.clips, duration: CMTimeGetSeconds(timeRange.duration))
        self.renderSize = renderSize
        self.renderScale = renderScale
        self.vectorRenderScale = max(vectorRenderScale ?? renderScale, renderScale, 0.000_001)
        self.viewport = viewport ?? RenderViewport(renderSize: renderSize)
        self.backgroundColor = backgroundColor
        self.frameDuration = frameDuration
        self.qualityProfile = qualityProfile
        self.failurePolicy = failurePolicy
        self.livePreviewState = livePreviewState
        self.requiredSourceTrackIDs = sourceTrackIDs
            .filter { $0 != kCMPersistentTrackID_Invalid }
            .map { NSNumber(value: $0) }
        super.init()
    }

    func activeClips(at time: Double) -> [RenderClipDescriptor] {
        var lower = 0
        var upper = clipIntervals.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if clipIntervals[midpoint].end <= time {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        guard clipIntervals.indices.contains(lower) else { return [] }
        let interval = clipIntervals[lower]
        var active = time >= interval.start && time < interval.end ? interval.clips : []
        let frameEnd = time + frameDuration
        for clip in clips where clip.text != nil
            && clip.timelineStart > time
            && clip.timelineStart < frameEnd
            && clip.timelineStart + clip.duration > time
            && !active.contains(where: { $0.clipID == clip.clipID })
        {
            active.append(clip)
        }
        return active.sorted { $0.renderOrder < $1.renderOrder }
    }

    private static func makeIntervals(
        clips: [RenderClipDescriptor],
        duration: Double
    ) -> [RenderClipInterval] {
        let boundaries = ([0, duration] + clips.flatMap {
            [$0.timelineStart, min($0.timelineStart + $0.duration, duration)]
        })
        .map { min(max($0, 0), duration) }
        .sorted()
        .reduce(into: [Double]()) { values, value in
            if values.last.map({ abs($0 - value) > 0.000_001 }) ?? true {
                values.append(value)
            }
        }

        return zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
            guard end - start > 0.000_001 else { return nil }
            return RenderClipInterval(
                start: start,
                end: end,
                clips: clips.filter {
                    $0.timelineStart < end && $0.timelineStart + $0.duration > start
                }
            )
        }
    }
}

enum PreviewQuality: Equatable {
    case interactive
    case balanced
    case full

    var maximumDimension: Double? {
        switch self {
        case .interactive: nil
        case .balanced: 1280
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

private struct PreviewRenderGraph {
    let topology: PreviewTopology
    let rendered: RenderedComposition
    let renderDescriptors: [RenderClipDescriptor]
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

private extension EditorProject {
    var requiresFullResolutionPreviewRender: Bool {
        containsGeneratedCanvasLayer(in: tracks)
    }

    func containsGeneratedCanvasLayer(in tracks: [TimelineTrack]) -> Bool {
        for track in tracks {
            for item in track.items {
                switch item {
                case .shape, .text:
                    return true
                case .compound(let compound):
                    if let sequence = sequences[compound.sequenceID],
                        containsGeneratedCanvasLayer(in: sequence.tracks)
                    {
                        return true
                    }
                case .media, .caption, .adjustment:
                    continue
                }
            }
        }
        return false
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

/// Converts an editor project into AVFoundation preview/export assets.
final class CompositionRenderService {
    private let timescale: CMTimeScale = 600
    private let retimingTimescale: CMTimeScale = 60_000
    private let assetCache: MediaAssetCache
    let livePreviewState = LivePreviewRenderState()
    @MainActor private var previewGraph: PreviewRenderGraph?

    init(assetCache: MediaAssetCache = .shared) {
        self.assetCache = assetCache
    }

    @MainActor
    func preparePreview(
        for project: EditorProject,
        quality: PreviewQuality,
        invalidation: EditorInvalidation
    ) async throws -> PreparedPreview? {
        let topology = PreviewTopology(project: project)
        let renderSettings = previewRenderSettings(
            for: project,
            quality: quality,
            livePreviewState: livePreviewState
        )
        let requiresTopologyBuild =
            invalidation.contains(.compositionTopology)
            || previewGraph?.topology != topology

        if requiresTopologyBuild {
            let rendered = try await makeComposition(
                for: project,
                renderSettings: renderSettings,
                backgroundRemovalPolicy: .omitUnavailable,
                qualityProfile: quality.renderQualityProfile,
                failurePolicy: .skipUnavailableEffects,
                livePreviewState: livePreviewState
            )
            try Task.checkCancellation()
            guard rendered.duration > 0 else {
                previewGraph = nil
                return nil
            }
            previewGraph = PreviewRenderGraph(
                topology: topology,
                rendered: rendered,
                renderDescriptors: rendered.videoComposition != nil
                    ? compileRenderDescriptors(
                        project: project,
                        visualTrackIDs: rendered.visualTrackIDs,
                        sourceTransforms: rendered.sourceTransforms,
                        backgroundMaskTrackIDs: rendered.backgroundMaskTrackIDs,
                        backgroundMaskTransforms: rendered.backgroundMaskTransforms
                    )
                    : []
            )
            return PreparedPreview(
                composition: rendered.composition,
                videoComposition: rendered.videoComposition,
                audioMix: rendered.audioMix,
                duration: rendered.duration,
                topologyWasRebuilt: true
            )
        }

        guard let graph = previewGraph else { return nil }
        let descriptors =
            invalidation.contains(.previewFrame)
            ? compileRenderDescriptors(
                project: project,
                visualTrackIDs: graph.rendered.visualTrackIDs,
                sourceTransforms: graph.rendered.sourceTransforms,
                backgroundMaskTrackIDs: graph.rendered.backgroundMaskTrackIDs,
                backgroundMaskTransforms: graph.rendered.backgroundMaskTransforms
            )
            : graph.renderDescriptors
        let videoComposition =
            invalidation.contains(.previewFrame)
            ? makeVideoComposition(
                renderSettings: renderSettings,
                renderScale: CGFloat(renderSettings.width)
                    / CGFloat(max(project.renderSettings.width, 1)),
                vectorRenderScale: vectorRenderScale(
                    renderSettings: renderSettings,
                    projectSettings: project.renderSettings,
                    qualityProfile: quality.renderQualityProfile
                ),
                clips: descriptors,
                sourceTrackIDs: sourceTrackIDs(
                    for: descriptors,
                    videoClockTrackID: graph.rendered.videoClockTrackID
                ),
                duration: project.duration,
                qualityProfile: quality.renderQualityProfile,
                failurePolicy: .skipUnavailableEffects,
                livePreviewState: livePreviewState
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
        excluding itemID: UUID
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

        let renderSettings = previewRenderSettings(for: project, quality: .balanced)
        let rendered = try await makeComposition(
            for: backgroundProject,
            renderSettings: renderSettings,
            backgroundRemovalPolicy: .omitUnavailable,
            qualityProfile: .balanced,
            failurePolicy: .skipUnavailableEffects
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
        renderSettings: RenderSettings
    ) async throws -> RenderedComposition {
        try await makeComposition(
            for: project,
            renderSettings: renderSettings,
            backgroundRemovalPolicy: .omitUnavailable,
            qualityProfile: .balanced,
            failurePolicy: .skipUnavailableEffects
        )
    }

    private func makeComposition(
        for project: EditorProject,
        renderSettings: RenderSettings,
        backgroundRemovalPolicy: BackgroundRemovalAvailabilityPolicy,
        qualityProfile: RenderQualityProfile,
        failurePolicy: RenderFailurePolicy,
        livePreviewState: LivePreviewRenderState? = nil
    ) async throws -> RenderedComposition {
        let composition = AVMutableComposition()
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
            for item in track.items.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                try Task.checkCancellation()
                switch item {
                case .media(let mediaItem):
                    guard mediaItem.sourceRange.duration > 0 else { continue }
                    try await insertVisualItem(
                        source: TimelineVisualSource(mediaItem),
                        project: project,
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
                case .caption, .adjustment, .compound:
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
                    metadata = try await assetCache.metadata(for: asset.url)
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

        let duration = max(project.duration, 0)
        if duration > 0,
            renderClips.contains(where: {
                $0.text != nil || $0.shape != nil || $0.stillImageURL != nil
            })
        {
            videoClockTrackID = try await insertGeneratedVideoClock(
                duration: duration,
                frameRate: renderSettings.frameRate,
                composition: composition
            )
        }
        let videoComposition = makeVideoComposition(
            renderSettings: renderSettings,
            renderScale: CGFloat(renderSettings.width)
                / CGFloat(max(project.renderSettings.width, 1)),
            vectorRenderScale: vectorRenderScale(
                renderSettings: renderSettings,
                projectSettings: project.renderSettings,
                qualityProfile: qualityProfile
            ),
            clips: renderClips,
            sourceTrackIDs: sourceTrackIDs(
                for: renderClips,
                videoClockTrackID: videoClockTrackID
            ),
            duration: duration,
            qualityProfile: qualityProfile,
            failurePolicy: failurePolicy,
            livePreviewState: livePreviewState
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
        duration: Double,
        qualityProfile: RenderQualityProfile,
        failurePolicy: RenderFailurePolicy,
        livePreviewState: LivePreviewRenderState? = nil
    ) -> AVVideoComposition? {
        guard !clips.isEmpty, duration > 0 else { return nil }

        var configuration = AVVideoComposition.Configuration()
        configuration.customVideoCompositorClass = MotionaryVideoCompositor.self
        configuration.renderSize = renderSettings.size
        configuration.frameDuration = CMTime(value: 1, timescale: renderSettings.frameRate)
        configuration.instructions = [
            MotionaryVideoCompositionInstruction(
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
                livePreviewState: livePreviewState
            )
        ]
        return AVVideoComposition(configuration: configuration)
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
        let url = try await MediaConversionHelper.blankVideoClockURL(
            duration: duration,
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
        try destinationTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: cmTime(duration)),
            of: sourceTrack,
            at: .zero
        )
        return destinationTrack.trackID
    }

    private func previewRenderSettings(
        for project: EditorProject,
        quality: PreviewQuality,
        livePreviewState: LivePreviewRenderState? = nil
    ) -> RenderSettings {
        let settings = project.renderSettings
        guard quality == .interactive || !project.requiresFullResolutionPreviewRender else {
            return settings
        }
        guard let maximumDimension = quality.maximumDimension else { return settings }
        let width = Double(max(settings.width, 1))
        let height = Double(max(settings.height, 1))
        let scale = min(1, maximumDimension / max(width, height))

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
        qualityProfile: RenderQualityProfile
    ) -> CGFloat {
        let logicalScale = CGFloat(renderSettings.width)
            / CGFloat(max(projectSettings.width, 1))
        switch qualityProfile {
        case .interactive, .export:
            return logicalScale
        case .balanced:
            return max(logicalScale, 1)
        }
    }

    private func insertVisualItem(
        source: TimelineVisualSource,
        project: EditorProject,
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
        if source.mediaType == .image, Self.isStillImageFile(mediaAsset.url) {
            visualTrackIDs[source.id] = kCMPersistentTrackID_Invalid
            renderClips.append(
                RenderClipDescriptor(
                    trackID: kCMPersistentTrackID_Invalid,
                    backgroundMaskTrackID: nil,
                    stillImageURL: mediaAsset.url,
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
            metadata = try await assetCache.metadata(for: mediaAsset.url)
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
        guard let sourceVideoTrack = metadata.videoTrack else {
            if sourceAvailabilityPolicy == .required {
                throw CompositionRenderError.visualTrackUnavailable(source.name)
            }
            return
        }

        guard
            let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
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
        } else {
            try insertRetimedTrack(
                sourceTrack: sourceVideoTrack,
                compositionTrack: compositionVideoTrack,
                sourceRange: source.sourceRange,
                timelineStart: source.timelineStart,
                speedMap: source.speedMap
            )
        }

        let sourceTransform = VideoSourceGeometry.normalizedTransform(
            naturalSize: metadata.naturalSize ?? .zero,
            transform: metadata.preferredTransform
        )
        sourceTransforms[source.id] = sourceTransform
        let visuals = source.visuals
        var backgroundMaskTrackID: CMPersistentTrackID?
        var backgroundMaskSourceTransform = CGAffineTransform.identity
        if source.shape == nil, visuals.backgroundRemoval != nil {
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
                    let maskMetadata = try await assetCache.metadata(for: artifact.url)
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
                    try insertRetimedTrack(
                        sourceTrack: maskSourceTrack,
                        compositionTrack: maskCompositionTrack,
                        sourceRange: maskSourceRange,
                        timelineStart: source.timelineStart,
                        speedMap: source.speedMap
                    )
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
        renderClips.append(
            RenderClipDescriptor(
                trackID: compositionVideoTrack.trackID,
                backgroundMaskTrackID: backgroundMaskTrackID,
                clipID: source.id,
                timelineStart: source.timelineStart,
                duration: source.timelineDuration,
                sourceTransform: sourceTransform,
                backgroundMaskSourceTransform: backgroundMaskSourceTransform,
                transform: visuals.transform,
                adjustments: visuals.adjustments,
                effectStack: visuals.effectStack,
                mask: visuals.mask,
                backgroundRemoval: backgroundMaskTrackID == nil ? nil : visuals.backgroundRemoval,
                blendMode: visuals.blendMode,
                blendIntensity: visuals.blendIntensity,
                shape: source.shape,
                text: nil,
                renderOrder: renderOrder
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

    private static func isStillImageFile(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0,
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
        else { return false }

        // Creating an image source only validates the container header. Force a
        // tiny decode so corrupt payloads fail during composition preflight
        // instead of disappearing silently inside the frame renderer.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 8,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) != nil
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
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTimePitchAlgorithm = pitchFollowsSpeed ? .varispeed : .timeDomain
        let points = AudioEnvelopeSampler.points(
            for: volume,
            duration: timelineDuration,
            frameRate: frameRate
        )
        guard let first = points.first else {
            parameters.setVolume(Float(volume.baseValue), at: cmTime(timelineStart))
            return parameters
        }

        parameters.setVolume(Float(first.value), at: cmTime(timelineStart + first.time))
        for pair in zip(points, points.dropFirst()) {
            let start = pair.0
            let end = pair.1
            let segmentDuration = end.time - start.time
            guard segmentDuration > 0.000_001 else {
                parameters.setVolume(
                    Float(end.value),
                    at: cmTime(timelineStart + end.time)
                )
                continue
            }
            parameters.setVolumeRamp(
                fromStartVolume: Float(start.value),
                toEndVolume: Float(end.value),
                timeRange: CMTimeRange(
                    start: cmTime(timelineStart + start.time),
                    duration: cmTime(segmentDuration)
                )
            )
        }
        return parameters
    }

    private func makeAudioMix(parameters: [AVAudioMixInputParameters]) -> AVAudioMix? {
        guard !parameters.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    @MainActor
    private func compileRenderDescriptors(
        project: EditorProject,
        visualTrackIDs: [UUID: CMPersistentTrackID],
        sourceTransforms: [UUID: CGAffineTransform],
        backgroundMaskTrackIDs: [UUID: CMPersistentTrackID],
        backgroundMaskTransforms: [UUID: CGAffineTransform]
    ) -> [RenderClipDescriptor] {
        var descriptors: [RenderClipDescriptor] = []
        var renderOrder = 0
        let visualTracks = project.tracks.filter {
            ($0.kind == .visual || $0.kind == .shape || $0.kind == .text) && !$0.isMuted
        }
        for track in visualTracks.reversed() {
            for item in track.items.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                switch item {
                case .media(let mediaItem):
                    guard let trackID = visualTrackIDs[mediaItem.id]
                    else { continue }
                    let visuals = mediaItem.visuals
                    descriptors.append(
                        RenderClipDescriptor(
                            trackID: trackID,
                            backgroundMaskTrackID: backgroundMaskTrackIDs[mediaItem.id],
                            stillImageURL: project.mediaLibrary[mediaItem.mediaID].flatMap {
                                mediaItem.mediaType == .image && Self.isStillImageFile($0.url)
                                    ? $0.url
                                    : nil
                            },
                            clipID: mediaItem.id,
                            timelineStart: mediaItem.timelineStart,
                            duration: mediaItem.timelineDuration,
                            sourceTransform: sourceTransforms[mediaItem.id] ?? .identity,
                            backgroundMaskSourceTransform: backgroundMaskTransforms[mediaItem.id] ?? .identity,
                            transform: visuals.transform,
                            adjustments: visuals.adjustments,
                            effectStack: visuals.effectStack,
                            mask: visuals.mask,
                            backgroundRemoval: backgroundMaskTrackIDs[mediaItem.id] == nil
                                ? nil
                                : visuals.backgroundRemoval,
                            blendMode: visuals.blendMode,
                            blendIntensity: visuals.blendIntensity,
                            shape: nil,
                            text: nil,
                            renderOrder: renderOrder
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
                case .caption, .adjustment, .compound:
                    continue
                }
            }
        }
        return descriptors
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

struct AudioEnvelopePoint: Equatable {
    var time: Double
    var value: Double
}

enum AudioEnvelopeSampler {
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

        let boundaries =
            ([0, safeDuration] + property.keyframes.map(\.time))
            .map { min(max($0, 0), safeDuration) }
            .sorted()
            .reduce(into: [Double]()) { values, value in
                if values.last.map({ abs($0 - value) > 0.000_001 }) ?? true {
                    values.append(value)
                }
            }
        let minimumInterval = 0.25 / Double(max(frameRate, 1))
        var result: [AudioEnvelopePoint] = []

        for pair in zip(boundaries, boundaries.dropFirst()) {
            appendAdaptiveSegment(
                property: property,
                start: pair.0,
                end: pair.1,
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
            result[result.count - 1] = point
        } else {
            result.append(point)
        }
    }
}
