import CoreMedia
import CoreImage
import Foundation
import Testing

@testable import Motionary

struct SmoothMotionTests {
    @Test func nativeInterpolationRejectsAFlashBetweenSimilarFrames() {
        let extent = CGRect(x: 0, y: 0, width: 320, height: 180)
        let first = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18)).cropped(to: extent)
        let second = CIImage(color: CIColor(red: 0.23, green: 0.23, blue: 0.23)).cropped(to: extent)
        let flash = CIImage(color: .white).cropped(to: extent)
        let next = CMTime(value: 1, timescale: 30)
        let check = SmoothMotionInterpolationCheck()
        #expect(check.accepts(first, between: first, and: second, current: .zero, next: next))
        #expect(!check.accepts(flash, between: first, and: second, current: .zero, next: next))
    }

    @Test func increasedFrameRateUsesAnExactIntermediatePhase() throws {
        let recipe = makeRecipe(speedMap: .constant, rate: 60)
        let time = 1.0 / 60
        let phase = try #require(recipe.interpolationPhase(
            at: time, target: recipe.sourceTime(at: time), current: .zero,
            next: CMTime(value: 1, timescale: 30)))
        #expect(abs(phase - 0.5) < 0.000_01)
        #expect(recipe.interpolationPhase(
            at: 0, target: .zero, current: .zero, next: CMTime(value: 1, timescale: 30)) == nil)
    }

    @Test func remappedReverseUsesPresentationOrderAndFreezeKeepsTheOriginal() throws {
        var map = SpeedMap.constant
        var remap = try #require(TimeRemap(sourceDuration: 1, timelineDuration: 2))
        remap.setSourceTime(1, at: 0, tolerance: 0.001)
        remap.setSourceTime(0, at: 2, tolerance: 0.001)
        map.timeRemap = remap
        let reverse = makeRecipe(speedMap: map, rate: 30)
        let time = 1.0 / 30
        let start = CMTime(value: 29, timescale: 30)
        let next = CMTime(value: 30, timescale: 30)
        // Give the neighboring source frame room inside the trim.
        let span = SmoothMotionRecipe(sourceRange: TimeRangeValue(start: 0, duration: 1.25),
            speedMap: map, timelineStart: 0, frameRate: 30)
        #expect(reverse.interpolationPhase(at: time, target: reverse.sourceTime(at: time),
            current: start, next: next) == nil)
        let phase = try #require(span.interpolationPhase(at: time, target: span.sourceTime(at: time),
            current: start, next: next))
        #expect(abs(phase - 0.5) < 0.001)

        remap.setInterpolation(.hold, at: 0)
        map.timeRemap = remap
        let freeze = makeRecipe(speedMap: map, rate: 60)
        #expect(freeze.interpolationPhase(at: 1, target: CMTime(value: 1, timescale: 60),
            current: .zero, next: CMTime(value: 1, timescale: 30)) == nil)
    }

    @Test(arguments: SmoothMotionMode.allCases)
    func projectAt120FramesPerSecondResamplesEachMissingFrame(mode: SmoothMotionMode) throws {
        let recipe = SmoothMotionRecipe(sourceRange: TimeRangeValue(start: 0, duration: 1),
            speedMap: .constant, timelineStart: 0, frameRate: 120, mode: mode)
        let next = CMTime(value: 1, timescale: 30)
        for index in 1...3 {
            let time = Double(index) / 120
            let phase = try #require(recipe.interpolationPhase(at: time, target: recipe.sourceTime(at: time),
                current: .zero, next: next))
            #expect(abs(phase - Float(index) / 4) < 0.001)
        }
    }

    @Test func preparedClipTracksFrameGridAlignmentAndSurvivesProjectRoundTrip() throws {
        let plain = makeRecipe(speedMap: .constant, rate: 30)
        let shifted = SmoothMotionRecipe(sourceRange: plain.sourceRange, speedMap: plain.speedMap,
            timelineStart: 1.025, frameRate: 30)
        #expect(abs(shifted.firstFrameOffset - (1.0 / 30 - 0.025)) < 0.000_01)
        #expect(SmoothMotionRecipe(sourceRange: plain.sourceRange, speedMap: plain.speedMap,
            timelineStart: 1, frameRate: 30) == plain)
        let clip = MediaTimelineItem(name: "Clip", mediaID: MediaID(), mediaType: .video,
            timelineStart: 0, sourceRange: plain.sourceRange, usesSmoothMotion: true, smoothMotionMode: .opticalFlow)
        let data = try JSONEncoder().encode(clip)
        #expect(try JSONDecoder().decode(MediaTimelineItem.self, from: data).usesSmoothMotion)
        #expect(try JSONDecoder().decode(MediaTimelineItem.self, from: data).smoothMotionMode == .opticalFlow)
        var oldProjectClip = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        oldProjectClip.removeValue(forKey: "usesSmoothMotion")
        oldProjectClip.removeValue(forKey: "smoothMotionMode")
        let legacy = try JSONSerialization.data(withJSONObject: oldProjectClip)
        let decodedLegacy = try JSONDecoder().decode(MediaTimelineItem.self, from: legacy)
        #expect(!decodedLegacy.usesSmoothMotion)
        #expect(decodedLegacy.smoothMotionMode == .frameGen)
    }

    private func makeRecipe(speedMap: SpeedMap, rate: Int32) -> SmoothMotionRecipe {
        SmoothMotionRecipe(sourceRange: TimeRangeValue(start: 0, duration: 1),
            speedMap: speedMap, timelineStart: 0, frameRate: rate)
    }
}
