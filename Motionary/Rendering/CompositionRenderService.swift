// AVFoundation composition construction shared by preview and export.

@preconcurrency import AVFoundation
import CoreGraphics

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
}

/// Per-clip information consumed by the custom video compositor.
struct RenderClipDescriptor {
    var trackID: CMPersistentTrackID
    var clipID: UUID
    var timelineStart: Double
    var duration: Double
    var sourceTransform: CGAffineTransform
    var transform: ClipTransform
    var adjustments: AdjustmentSettings
    var effectStack: EffectStack
    var renderOrder: Int
}

/// Video composition instruction containing all clips active in a render interval.
final class MotionaryVideoCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let clips: [RenderClipDescriptor]
    let renderSize: CGSize

    init(timeRange: CMTimeRange, clips: [RenderClipDescriptor], renderSize: CGSize) {
        self.timeRange = timeRange
        self.clips = clips.sorted { $0.renderOrder < $1.renderOrder }
        self.renderSize = renderSize
        self.requiredSourceTrackIDs = clips.map { NSNumber(value: $0.trackID) }
        super.init()
    }
}

/// Converts an editor project into AVFoundation preview/export assets.
struct CompositionRenderService {
    private let timescale: CMTimeScale = 600

    @MainActor
    func makePlayerItem(for project: EditorProject) async throws -> AVPlayerItem? {
        let rendered = try await makeComposition(for: project)
        guard rendered.duration > 0 else { return nil }
        let item = AVPlayerItem(asset: rendered.composition)
        item.videoComposition = rendered.videoComposition
        item.audioMix = rendered.audioMix
        return item
    }

    func makeComposition(for project: EditorProject) async throws -> RenderedComposition {
        let composition = AVMutableComposition()
        var renderClips: [RenderClipDescriptor] = []
        var audioParameters: [AVAudioMixInputParameters] = []
        var renderOrder = 0

        let visualTracks = project.tracks.filter { $0.kind == .visual && !$0.isMuted }
        for track in visualTracks.reversed() {
            for clip in track.clips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                guard clip.sourceRange.duration > 0 else { continue }
                let asset = AVURLAsset(url: clip.source.url)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                guard let sourceVideoTrack = videoTracks.first else { continue }

                guard
                    let compositionVideoTrack = composition.addMutableTrack(
                        withMediaType: .video,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                else { continue }

                if clip.mediaType == .image {
                    let assetDuration = CMTimeGetSeconds(try await asset.load(.duration))
                    try insertLoopedStillImageVideo(
                        clip: clip,
                        assetDuration: assetDuration,
                        sourceVideoTrack: sourceVideoTrack,
                        compositionVideoTrack: compositionVideoTrack,
                        frameRate: project.renderSettings.frameRate
                    )
                } else {
                    let sourceRange = CMTimeRange(
                        start: cmTime(clip.sourceRange.start),
                        duration: cmTime(clip.sourceRange.duration)
                    )
                    try compositionVideoTrack.insertTimeRange(
                        sourceRange, of: sourceVideoTrack, at: cmTime(clip.timelineStart))
                }

                let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
                let naturalSize = try await sourceVideoTrack.load(.naturalSize)
                renderClips.append(
                    RenderClipDescriptor(
                        trackID: compositionVideoTrack.trackID,
                        clipID: clip.id,
                        timelineStart: clip.timelineStart,
                        duration: clip.sourceRange.duration,
                        sourceTransform: VideoSourceGeometry.normalizedTransform(
                            naturalSize: naturalSize,
                            transform: preferredTransform
                        ),
                        transform: clip.transform,
                        adjustments: clip.adjustments,
                        effectStack: clip.effectStack,
                        renderOrder: renderOrder
                    )
                )
                renderOrder += 1

                let audioTracks: [AVAssetTrack]
                if clip.mediaType == .image || clip.volume.maximumValue <= 0.001 {
                    audioTracks = []
                } else {
                    audioTracks = try await asset.loadTracks(withMediaType: .audio)
                }
                if let sourceAudioTrack = audioTracks.first,
                    let compositionAudioTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                {
                    let sourceRange = CMTimeRange(
                        start: cmTime(clip.sourceRange.start),
                        duration: cmTime(clip.sourceRange.duration)
                    )
                    try compositionAudioTrack.insertTimeRange(
                        sourceRange, of: sourceAudioTrack, at: cmTime(clip.timelineStart))
                    audioParameters.append(
                        makeAudioParameters(
                            track: compositionAudioTrack,
                            clip: clip,
                            frameRate: project.renderSettings.frameRate
                        )
                    )
                }
            }
        }

        for track in project.tracks where track.kind == .audio && !track.isMuted {
            for clip in track.clips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                guard clip.sourceRange.duration > 0, clip.volume.maximumValue > 0.001 else { continue }
                let asset = AVURLAsset(url: clip.source.url)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                guard let sourceAudioTrack = audioTracks.first,
                    let compositionAudioTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                else { continue }

                let sourceRange = CMTimeRange(
                    start: cmTime(clip.sourceRange.start),
                    duration: cmTime(clip.sourceRange.duration)
                )
                try compositionAudioTrack.insertTimeRange(
                    sourceRange, of: sourceAudioTrack, at: cmTime(clip.timelineStart))
                audioParameters.append(
                    makeAudioParameters(
                        track: compositionAudioTrack,
                        clip: clip,
                        frameRate: project.renderSettings.frameRate
                    )
                )
            }
        }

        let duration = max(project.duration, 0)
        let videoComposition = makeVideoComposition(
            renderSettings: project.renderSettings,
            clips: renderClips,
            duration: duration
        )

        return RenderedComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: makeAudioMix(parameters: audioParameters),
            duration: duration,
            hasVideo: !renderClips.isEmpty
        )
    }

    private func makeVideoComposition(
        renderSettings: RenderSettings,
        clips: [RenderClipDescriptor],
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
                renderSize: renderSettings.size
            )
        ]
        return AVVideoComposition(configuration: configuration)
    }

    private func insertLoopedStillImageVideo(
        clip: TimelineClip,
        assetDuration: Double,
        sourceVideoTrack: AVAssetTrack,
        compositionVideoTrack: AVMutableCompositionTrack,
        frameRate: Int32
    ) throws {
        let minimumSegmentDuration = 1 / Double(max(frameRate, 1))
        let loopDuration = max(
            min(
                assetDuration.isFinite ? assetDuration : clip.source.originalDuration,
                clip.source.originalDuration > 0 ? clip.source.originalDuration : Double.greatestFiniteMagnitude
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

    private func makeAudioParameters(
        track: AVCompositionTrack,
        clip: TimelineClip,
        frameRate: Int32
    ) -> AVAudioMixInputParameters {
        let parameters = AVMutableAudioMixInputParameters(track: track)
        let points = AudioEnvelopeSampler.points(
            for: clip.volume,
            duration: clip.sourceRange.duration,
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
