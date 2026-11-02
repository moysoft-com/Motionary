import Testing
@testable import Motionary

struct AudioSampleTimelineTests {
    @Test func preservesGapsAndDropsOverlappingSamples() {
        var timeline = AudioSampleTimeline()
        #expect(timeline.place(startFrame: 100, frameCount: 200) == .init(silenceFrames: 100, skippedFrames: 0))
        #expect(timeline.nextFrame == 300)
        #expect(timeline.place(startFrame: 298, frameCount: 5) == .init(silenceFrames: 0, skippedFrames: 2))
        #expect(timeline.nextFrame == 303)
        #expect(timeline.place(startFrame: 500, frameCount: 10) == .init(silenceFrames: 197, skippedFrames: 0))
        #expect(timeline.nextFrame == 510)
    }

    @Test func extremeNegativeTimestampCannotOverflow() {
        var timeline = AudioSampleTimeline()
        #expect(timeline.place(startFrame: .min, frameCount: 16) == .init(silenceFrames: 0, skippedFrames: 16))
        #expect(timeline.nextFrame == 0)
    }

    @Test func negativePrerollAndTimestampRoundingDoNotShiftTheTimeline() {
        var timeline = AudioSampleTimeline()
        #expect(timeline.place(startFrame: -10, frameCount: 20) == .init(silenceFrames: 0, skippedFrames: 10))
        #expect(timeline.nextFrame == 10)
        #expect(timeline.place(startFrame: 11, frameCount: 8) == .init(silenceFrames: 0, skippedFrames: 0))
        #expect(timeline.nextFrame == 18)
        #expect(timeline.place(startFrame: nil, frameCount: 2) == .init(silenceFrames: 0, skippedFrames: 0))
        #expect(timeline.nextFrame == 20)
    }
}
