import AVFoundation
import CoreGraphics

struct RenderedComposition {
    var composition: AVMutableComposition
    var videoComposition: AVMutableVideoComposition?
    var duration: Double
    var hasVideo: Bool
}

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

final class MotionaryVideoCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
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

struct CompositionRenderService {
    private let timescale: CMTimeScale = 600

    func makePlayerItem(for project: EditorProject) async throws -> AVPlayerItem? {
        let rendered = try await makeComposition(for: project)
        guard rendered.duration > 0 else { return nil }
        let item = AVPlayerItem(asset: rendered.composition)
        item.videoComposition = rendered.videoComposition
        return item
    }

    func makeComposition(for project: EditorProject) async throws -> RenderedComposition {
        let composition = AVMutableComposition()
        var renderClips: [RenderClipDescriptor] = []
        var renderOrder = 0

        let visualTracks = project.tracks.filter { $0.kind == .visual && !$0.isMuted }
        for track in visualTracks.reversed() {
            for clip in track.clips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                guard clip.sourceRange.duration > 0 else { continue }
                let asset = AVURLAsset(url: clip.source.url)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                guard let sourceVideoTrack = videoTracks.first else { continue }

                guard let compositionVideoTrack = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { continue }

                let sourceRange = CMTimeRange(
                    start: cmTime(clip.sourceRange.start),
                    duration: cmTime(clip.sourceRange.duration)
                )
                try compositionVideoTrack.insertTimeRange(sourceRange, of: sourceVideoTrack, at: cmTime(clip.timelineStart))

                let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
                renderClips.append(
                    RenderClipDescriptor(
                        trackID: compositionVideoTrack.trackID,
                        clipID: clip.id,
                        timelineStart: clip.timelineStart,
                        duration: clip.sourceRange.duration,
                        sourceTransform: preferredTransform,
                        transform: clip.transform,
                        adjustments: clip.adjustments,
                        effectStack: clip.effectStack,
                        renderOrder: renderOrder
                    )
                )
                renderOrder += 1

                let audioTracks = clip.volume > 0.001 ? try await asset.loadTracks(withMediaType: .audio) : []
                if let sourceAudioTrack = audioTracks.first,
                   let compositionAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                   ) {
                    try compositionAudioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: cmTime(clip.timelineStart))
                }
            }
        }

        for track in project.tracks where track.kind == .audio && !track.isMuted {
            for clip in track.clips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                guard clip.sourceRange.duration > 0, clip.volume > 0.001 else { continue }
                let asset = AVURLAsset(url: clip.source.url)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                guard let sourceAudioTrack = audioTracks.first,
                      let compositionAudioTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                      ) else { continue }

                let sourceRange = CMTimeRange(
                    start: cmTime(clip.sourceRange.start),
                    duration: cmTime(clip.sourceRange.duration)
                )
                try compositionAudioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: cmTime(clip.timelineStart))
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
            duration: duration,
            hasVideo: !renderClips.isEmpty
        )
    }

    private func makeVideoComposition(renderSettings: RenderSettings, clips: [RenderClipDescriptor], duration: Double) -> AVMutableVideoComposition? {
        guard !clips.isEmpty, duration > 0 else { return nil }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = MotionaryVideoCompositor.self
        videoComposition.renderSize = renderSettings.size
        videoComposition.frameDuration = CMTime(value: 1, timescale: renderSettings.frameRate)
        videoComposition.instructions = [
            MotionaryVideoCompositionInstruction(
                timeRange: CMTimeRange(start: .zero, duration: cmTime(duration)),
                clips: clips,
                renderSize: renderSettings.size
            )
        ]
        return videoComposition
    }

    private func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }
}
