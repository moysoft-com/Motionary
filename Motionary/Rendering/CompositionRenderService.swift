// AVFoundation composition construction shared by preview and export.

@preconcurrency import AVFoundation
import CoreGraphics
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
}

/// Per-clip information consumed by the custom video compositor.
struct RenderClipDescriptor: @unchecked Sendable {
    let trackID: CMPersistentTrackID
    let clipID: UUID
    let timelineStart: Double
    let duration: Double
    let sourceTransform: CGAffineTransform
    let transform: ClipTransform
    let adjustments: AdjustmentSettings
    let effectStack: EffectStack
    let mask: ItemMask?
    let shape: ClipShape?
    let text: TextTimelineItem?
    let renderOrder: Int
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
    let backgroundColor: RGBAColor
    let frameDuration: Double

    init(
        timeRange: CMTimeRange,
        clips: [RenderClipDescriptor],
        sourceTrackIDs: [CMPersistentTrackID],
        renderSize: CGSize,
        renderScale: CGFloat,
        backgroundColor: RGBAColor,
        frameDuration: Double
    ) {
        self.timeRange = timeRange
        self.clips = clips.sorted { $0.renderOrder < $1.renderOrder }
        self.clipIntervals = Self.makeIntervals(clips: self.clips, duration: CMTimeGetSeconds(timeRange.duration))
        self.renderSize = renderSize
        self.renderScale = renderScale
        self.backgroundColor = backgroundColor
        self.frameDuration = frameDuration
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
        case .interactive: 640
        case .balanced: 1280
        case .full: nil
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
    let width: Int
    let height: Int
    let frameRate: Int32
    let quality: PreviewQuality
    let tracks: [PreviewTrackTopology]

    init(project: EditorProject, quality: PreviewQuality) {
        width = project.renderSettings.width
        height = project.renderSettings.height
        frameRate = project.renderSettings.frameRate
        self.quality = quality
        tracks = project.tracks.map {
            PreviewTrackTopology(
                id: $0.id,
                kind: $0.kind,
                isMuted: $0.isMuted,
                items: $0.items.map { item in
                    PreviewItemTopology(
                        id: item.id,
                        kind: item.kind,
                        mediaID: item.legacyClip()?.mediaID,
                        mediaType: item.legacyClip()?.mediaType,
                        timelineStart: item.timelineStart,
                        placementDuration: item.placementDuration,
                        sourceRange: item.legacyClip()?.sourceRange,
                        hasShape: {
                            if case .shape = item { return true }
                            return item.legacyClip()?.shape != nil
                        }(),
                        speedSignature: {
                            if case .media(let media) = item { return media.speedMap.topologySignature }
                            return 0
                        }()
                    )
                }
            )
        }
    }
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
    let timelineStart: Double
    let placementDuration: Double
    let sourceRange: TimeRangeValue?
    let hasShape: Bool
    let speedSignature: UInt64
}

/// Converts an editor project into AVFoundation preview/export assets.
final class CompositionRenderService {
    private let timescale: CMTimeScale = 600
    private let retimingTimescale: CMTimeScale = 60_000
    private let assetCache: MediaAssetCache
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
        let topology = PreviewTopology(project: project, quality: quality)
        let renderSettings = previewRenderSettings(for: project.renderSettings, quality: quality)
        let requiresTopologyBuild =
            invalidation.contains(.compositionTopology)
            || previewGraph?.topology != topology

        if requiresTopologyBuild {
            let rendered = try await makeComposition(
                for: project,
                renderSettings: renderSettings
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
                        sourceTransforms: rendered.sourceTransforms
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
                sourceTransforms: graph.rendered.sourceTransforms
            )
            : graph.renderDescriptors
        let videoComposition =
            invalidation.contains(.previewFrame)
            ? makeVideoComposition(
                renderSettings: renderSettings,
                renderScale: CGFloat(renderSettings.width)
                    / CGFloat(max(project.renderSettings.width, 1)),
                clips: descriptors,
                sourceTrackIDs: sourceTrackIDs(
                    for: descriptors,
                    videoClockTrackID: graph.rendered.videoClockTrackID
                ),
                duration: project.duration
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
                sourceTransforms: graph.rendered.sourceTransforms
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

    func makePreviewBackgroundImage(
        for project: EditorProject,
        at time: Double,
        excluding clipID: UUID
    ) async throws -> UIImage? {
        var backgroundProject = project
        guard let item = backgroundProject.item(id: clipID) else { return nil }
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
        backgroundProject.replaceItem(id: clipID, with: hiddenItem)

        let renderSettings = previewRenderSettings(for: project.renderSettings, quality: .balanced)
        let rendered = try await makeComposition(
            for: backgroundProject,
            renderSettings: renderSettings
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

    func makeComposition(for project: EditorProject) async throws -> RenderedComposition {
        try await makeComposition(for: project, renderSettings: project.renderSettings)
    }

    private func makeComposition(
        for project: EditorProject,
        renderSettings: RenderSettings
    ) async throws -> RenderedComposition {
        let composition = AVMutableComposition()
        var renderClips: [RenderClipDescriptor] = []
        var audioParameters: [AVAudioMixInputParameters] = []
        var visualTrackIDs: [UUID: CMPersistentTrackID] = [:]
        var audioTrackIDs: [UUID: CMPersistentTrackID] = [:]
        var sourceTransforms: [UUID: CGAffineTransform] = [:]
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
                    guard let clip = item.legacyClip(), mediaItem.sourceRange.duration > 0 else { continue }
                    let timelineDuration = mediaItem.timelineDuration
                    try await insertVisualClip(
                        clip: clip,
                        timelineDuration: timelineDuration,
                        speedMap: mediaItem.speedMap,
                        pitchFollowsSpeed: mediaItem.pitchFollowsSpeed,
                        project: project,
                        composition: composition,
                        visualTrackIDs: &visualTrackIDs,
                        audioTrackIDs: &audioTrackIDs,
                        audioParameters: &audioParameters,
                        sourceTransforms: &sourceTransforms,
                        renderClips: &renderClips,
                        renderOrder: &renderOrder
                    )
                case .shape:
                    guard let clip = item.legacyClip(), clip.sourceRange.duration > 0 else { continue }
                    try await insertVisualClip(
                        clip: clip,
                        timelineDuration: clip.sourceRange.duration,
                        speedMap: .constant,
                        pitchFollowsSpeed: false,
                        project: project,
                        composition: composition,
                        visualTrackIDs: &visualTrackIDs,
                        audioTrackIDs: &audioTrackIDs,
                        audioParameters: &audioParameters,
                        sourceTransforms: &sourceTransforms,
                        renderClips: &renderClips,
                        renderOrder: &renderOrder
                    )
                case .text(let textItem):
                    renderClips.append(
                        RenderClipDescriptor(
                            trackID: kCMPersistentTrackID_Invalid,
                            clipID: textItem.id,
                            timelineStart: textItem.timelineStart,
                            duration: textItem.duration,
                            sourceTransform: .identity,
                            transform: textItem.visuals.transform,
                            adjustments: textItem.visuals.adjustments,
                            effectStack: textItem.visuals.effectStack,
                            mask: textItem.visuals.mask,
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
                    let clip = item.legacyClip(),
                    clip.sourceRange.duration > 0
                else { continue }
                let metadata = try await assetCache.metadata(for: project.mediaURL(for: clip))
                try Task.checkCancellation()
                guard let sourceAudioTrack = metadata.audioTrack,
                    let compositionAudioTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                else { continue }
                audioTrackIDs[clip.id] = compositionAudioTrack.trackID

                try insertRetimedTrack(
                    sourceTrack: sourceAudioTrack,
                    compositionTrack: compositionAudioTrack,
                    sourceRange: clip.sourceRange,
                    timelineStart: clip.timelineStart,
                    speedMap: mediaItem.speedMap
                )
                audioParameters.append(
                    makeAudioParameters(
                        track: compositionAudioTrack,
                        clip: clip,
                        timelineDuration: mediaItem.timelineDuration,
                        pitchFollowsSpeed: mediaItem.pitchFollowsSpeed,
                        frameRate: project.renderSettings.frameRate
                    )
                )
            }
        }

        let duration = max(project.duration, 0)
        if duration > 0,
            renderClips.contains(where: { $0.text != nil })
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
            clips: renderClips,
            sourceTrackIDs: sourceTrackIDs(
                for: renderClips,
                videoClockTrackID: videoClockTrackID
            ),
            duration: duration
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
            sourceTransforms: sourceTransforms
        )
    }

    private func makeVideoComposition(
        renderSettings: RenderSettings,
        renderScale: CGFloat,
        clips: [RenderClipDescriptor],
        sourceTrackIDs: [CMPersistentTrackID],
        duration: Double
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
                backgroundColor: renderSettings.backgroundColor,
                frameDuration: 1 / Double(max(renderSettings.frameRate, 1))
            )
        ]
        return AVVideoComposition(configuration: configuration)
    }

    private func sourceTrackIDs(
        for clips: [RenderClipDescriptor],
        videoClockTrackID: CMPersistentTrackID?
    ) -> [CMPersistentTrackID] {
        var result = clips
            .map(\.trackID)
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
        for settings: RenderSettings,
        quality: PreviewQuality
    ) -> RenderSettings {
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

    private func insertVisualClip(
        clip: TimelineClip,
        timelineDuration: Double,
        speedMap: SpeedMap,
        pitchFollowsSpeed: Bool,
        project: EditorProject,
        composition: AVMutableComposition,
        visualTrackIDs: inout [UUID: CMPersistentTrackID],
        audioTrackIDs: inout [UUID: CMPersistentTrackID],
        audioParameters: inout [AVAudioMixInputParameters],
        sourceTransforms: inout [UUID: CGAffineTransform],
        renderClips: inout [RenderClipDescriptor],
        renderOrder: inout Int
    ) async throws {
        let metadata = try await assetCache.metadata(for: project.mediaURL(for: clip))
        try Task.checkCancellation()
        guard let sourceVideoTrack = metadata.videoTrack else { return }

        guard
            let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else { return }
        visualTrackIDs[clip.id] = compositionVideoTrack.trackID

        if clip.mediaType == .image {
            try insertLoopedStillImageVideo(
                clip: clip,
                originalDuration: project.originalDuration(for: clip),
                assetDuration: metadata.duration,
                sourceVideoTrack: sourceVideoTrack,
                compositionVideoTrack: compositionVideoTrack,
                frameRate: project.renderSettings.frameRate
            )
        } else {
            try insertRetimedTrack(
                sourceTrack: sourceVideoTrack,
                compositionTrack: compositionVideoTrack,
                sourceRange: clip.sourceRange,
                timelineStart: clip.timelineStart,
                speedMap: speedMap
            )
        }

        let sourceTransform = VideoSourceGeometry.normalizedTransform(
            naturalSize: metadata.naturalSize ?? .zero,
            transform: metadata.preferredTransform
        )
        sourceTransforms[clip.id] = sourceTransform
        renderClips.append(
            RenderClipDescriptor(
                trackID: compositionVideoTrack.trackID,
                clipID: clip.id,
                timelineStart: clip.timelineStart,
                duration: timelineDuration,
                sourceTransform: sourceTransform,
                transform: clip.transform,
                adjustments: clip.adjustments,
                effectStack: clip.effectStack,
                mask: project.item(id: clip.id)?.editableVisuals?.mask,
                shape: clip.shape,
                text: nil,
                renderOrder: renderOrder
            )
        )
        renderOrder += 1

        let audioTracks: [AVAssetTrack]
        if !Self.shouldIncludeSourceAudio(for: clip) {
            audioTracks = []
        } else {
            audioTracks = metadata.audioTrack.map { [$0] } ?? []
        }
        if let sourceAudioTrack = audioTracks.first,
            let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        {
            audioTrackIDs[clip.id] = compositionAudioTrack.trackID
            try insertRetimedTrack(
                sourceTrack: sourceAudioTrack,
                compositionTrack: compositionAudioTrack,
                sourceRange: clip.sourceRange,
                timelineStart: clip.timelineStart,
                speedMap: speedMap
            )
            audioParameters.append(
                makeAudioParameters(
                    track: compositionAudioTrack,
                    clip: clip,
                    timelineDuration: timelineDuration,
                    pitchFollowsSpeed: pitchFollowsSpeed,
                    frameRate: project.renderSettings.frameRate
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

    private func insertLoopedStillImageVideo(
        clip: TimelineClip,
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
        var remainingDuration = max(clip.sourceRange.duration, 0)
        var timelineCursor = clip.timelineStart

        while remainingDuration > 0.0005 {
            let segmentDuration = min(loopDuration, remainingDuration)
            let sourceRange = CMTimeRange(
                start: .zero,
                duration: cmTime(segmentDuration)
            )
            try compositionVideoTrack.insertTimeRange(sourceRange, of: sourceVideoTrack, at: cmTime(timelineCursor))
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
        clip: TimelineClip,
        timelineDuration: Double? = nil,
        pitchFollowsSpeed: Bool = false,
        frameRate: Int32
    ) -> AVAudioMixInputParameters {
        let envelopeDuration = timelineDuration ?? clip.sourceRange.duration
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTimePitchAlgorithm = pitchFollowsSpeed ? .varispeed : .timeDomain
        let points = AudioEnvelopeSampler.points(
            for: clip.volume,
            duration: envelopeDuration,
            frameRate: frameRate
        )
        guard let first = points.first else {
            parameters.setVolume(Float(clip.volume.baseValue), at: cmTime(clip.timelineStart))
            return parameters
        }

        parameters.setVolume(Float(first.value), at: cmTime(clip.timelineStart + first.time))
        for pair in zip(points, points.dropFirst()) {
            let start = pair.0
            let end = pair.1
            let segmentDuration = end.time - start.time
            guard segmentDuration > 0.000_001 else {
                parameters.setVolume(
                    Float(end.value),
                    at: cmTime(clip.timelineStart + end.time)
                )
                continue
            }
            parameters.setVolumeRamp(
                fromStartVolume: Float(start.value),
                toEndVolume: Float(end.value),
                timeRange: CMTimeRange(
                    start: cmTime(clip.timelineStart + start.time),
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

    static func shouldIncludeSourceAudio(for clip: TimelineClip) -> Bool {
        clip.mediaType != .image
    }

    @MainActor
    private func compileRenderDescriptors(
        project: EditorProject,
        visualTrackIDs: [UUID: CMPersistentTrackID],
        sourceTransforms: [UUID: CGAffineTransform]
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
                    guard let clip = item.legacyClip(),
                        let trackID = visualTrackIDs[clip.id]
                    else { continue }
                    descriptors.append(
                        RenderClipDescriptor(
                            trackID: trackID,
                            clipID: clip.id,
                            timelineStart: clip.timelineStart,
                            duration: mediaItem.timelineDuration,
                            sourceTransform: sourceTransforms[clip.id] ?? .identity,
                            transform: clip.transform,
                            adjustments: clip.adjustments,
                            effectStack: clip.effectStack,
                            mask: mediaItem.visuals.mask,
                            shape: clip.shape,
                            text: nil,
                            renderOrder: renderOrder
                        )
                    )
                    renderOrder += 1
                case .shape:
                    guard let clip = item.legacyClip(),
                        let trackID = visualTrackIDs[clip.id]
                    else { continue }
                    descriptors.append(
                        RenderClipDescriptor(
                            trackID: trackID,
                            clipID: clip.id,
                            timelineStart: clip.timelineStart,
                            duration: clip.sourceRange.duration,
                            sourceTransform: sourceTransforms[clip.id] ?? .identity,
                            transform: clip.transform,
                            adjustments: clip.adjustments,
                            effectStack: clip.effectStack,
                            mask: item.editableVisuals?.mask,
                            shape: clip.shape,
                            text: nil,
                            renderOrder: renderOrder
                        )
                    )
                    renderOrder += 1
                case .text(let textItem):
                    descriptors.append(
                        RenderClipDescriptor(
                            trackID: kCMPersistentTrackID_Invalid,
                            clipID: textItem.id,
                            timelineStart: textItem.timelineStart,
                            duration: textItem.duration,
                            sourceTransform: .identity,
                            transform: textItem.visuals.transform,
                            adjustments: textItem.visuals.adjustments,
                            effectStack: textItem.visuals.effectStack,
                            mask: textItem.visuals.mask,
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
            .flatMap(\.clips)
            .compactMap { clip -> AVAudioMixInputParameters? in
                guard let trackID = audioTrackIDs[clip.id],
                    let track = composition.track(withTrackID: trackID)
                else { return nil }
                return makeAudioParameters(
                    track: track,
                    clip: clip,
                    timelineDuration: project.item(id: clip.id)?.placementDuration,
                    pitchFollowsSpeed: {
                        guard case .media(let item) = project.item(id: clip.id) else { return false }
                        return item.pitchFollowsSpeed
                    }(),
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
