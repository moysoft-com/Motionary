import AVFoundation
import Foundation
import Testing

@testable import Motionary

struct RenderIntervalIndexTests {
    @Test func intervalSweepMatchesBruteForceForDenseTimeline() throws {
        let descriptors = (0..<360).map { index in
            let lane = index % 18
            let group = index / 18
            return descriptor(
                start: Double(lane) * 0.17 + Double(group) * 0.031,
                duration: 0.28 + Double(index % 7) * 0.043,
                renderOrder: 359 - index
            )
        }
        let instruction = MotionaryVideoCompositionInstruction(
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: 8, preferredTimescale: 600)
            ),
            clips: Array(descriptors.reversed()),
            sourceTrackIDs: [],
            renderSize: CGSize(width: 960, height: 540),
            renderScale: 0.5,
            backgroundColor: .black,
            frameDuration: 1 / 60,
            qualityProfile: .interactive
        )

        for step in 0...1_600 {
            let time = Double(step) / 200
            let expected = descriptors
                .filter { $0.timelineStart <= time && $0.timelineStart + $0.duration > time }
                .sorted { $0.renderOrder < $1.renderOrder }
                .map(\.clipID)
            #expect(instruction.activeClips(at: time).map(\.clipID) == expected)
        }
    }

    @Test func intervalSweepPreservesHalfOpenBoundaries() {
        let first = descriptor(start: 0, duration: 1, renderOrder: 0)
        let second = descriptor(start: 1, duration: 1, renderOrder: 1)
        let instruction = MotionaryVideoCompositionInstruction(
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: 2, preferredTimescale: 600)
            ),
            clips: [first, second],
            sourceTrackIDs: [],
            renderSize: CGSize(width: 640, height: 360),
            renderScale: 1,
            backgroundColor: .black,
            frameDuration: 1 / 30
        )

        #expect(instruction.activeClips(at: 0).map(\.clipID) == [first.clipID])
        #expect(instruction.activeClips(at: 0.999_999).map(\.clipID) == [first.clipID])
        #expect(instruction.activeClips(at: 1).map(\.clipID) == [second.clipID])
        #expect(instruction.activeClips(at: 1.999_999).map(\.clipID) == [second.clipID])
        #expect(instruction.activeClips(at: 2).isEmpty)
    }

    @Test func intervalIndexPreservesSubMicrosecondClip() {
        let start = 0.25
        let duration = 0.000_000_5
        let clip = descriptor(start: start, duration: duration, renderOrder: 0)
        let instruction = MotionaryVideoCompositionInstruction(
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: 1, preferredTimescale: 1_000_000_000)
            ),
            clips: [clip],
            sourceTrackIDs: [],
            renderSize: CGSize(width: 640, height: 360),
            renderScale: 1,
            backgroundColor: .black,
            frameDuration: 1 / 60
        )

        #expect(instruction.clipIntervals.count == 1)
        #expect(instruction.activeClips(at: start).map(\.clipID) == [clip.clipID])
        #expect(
            instruction.activeClips(at: start + duration * 0.5).map(\.clipID)
                == [clip.clipID]
        )
        #expect(instruction.activeClips(at: start + duration).isEmpty)
    }

    @Test func denseOverlappingTimelineUsesLinearIndexStorage() {
        let descriptors = (0..<3_000).map { index in
            descriptor(
                start: Double(index) * 0.002,
                duration: 6,
                renderOrder: index
            )
        }
        let instruction = MotionaryVideoCompositionInstruction(
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: 12, preferredTimescale: 600)
            ),
            clips: descriptors,
            sourceTrackIDs: [],
            renderSize: CGSize(width: 960, height: 540),
            renderScale: 0.5,
            backgroundColor: .black,
            frameDuration: 1 / 60,
            qualityProfile: .interactive
        )

        #expect(instruction.clipIntervals.count == descriptors.count)
        #expect(instruction.clipIntervals.storageEntryCount <= descriptors.count * 3)
        for time in [0.0, 1.0, 3.0, 5.999, 6.0, 8.0, 11.999, 12.0] {
            let expected = descriptors
                .filter { $0.timelineStart <= time && $0.timelineStart + $0.duration > time }
                .map(\.clipID)
            #expect(instruction.activeClips(at: time).map(\.clipID) == expected)
        }
    }

    private func descriptor(
        start: Double,
        duration: Double,
        renderOrder: Int
    ) -> RenderClipDescriptor {
        RenderClipDescriptor(
            trackID: kCMPersistentTrackID_Invalid,
            backgroundMaskTrackID: nil,
            clipID: UUID(),
            timelineStart: start,
            duration: duration,
            sourceTransform: .identity,
            backgroundMaskSourceTransform: .identity,
            transform: ClipTransform(),
            adjustments: AdjustmentSettings(),
            effectStack: EffectStack(),
            mask: nil,
            backgroundRemoval: nil,
            blendMode: .normal,
            blendIntensity: 1,
            shape: nil,
            text: nil,
            renderOrder: renderOrder
        )
    }
}
