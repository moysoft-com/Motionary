// Focused compatibility and timing coverage for text-layer domain models.

import Foundation
import Testing

@testable import Motionary

struct TextAnimationDomainTests {
    @Test func legacyTextItemDecodesProfessionalTextDefaults() throws {
        let item = TextTimelineItem(
            text: "Legacy",
            style: TextStyle(fontName: "Helvetica", fontSize: 36, color: .orange),
            timelineStart: 1,
            duration: 4
        )
        let encoded = try JSONEncoder().encode(item)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "layout")
        object.removeValue(forKey: "animations")
        var style = try #require(object["style"] as? [String: Any])
        style.removeValue(forKey: "letterSpacing")
        style.removeValue(forKey: "lineSpacing")
        style.removeValue(forKey: "stroke")
        style.removeValue(forKey: "shadow")
        style.removeValue(forKey: "background")
        object["style"] = style

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TextTimelineItem.self, from: legacyData)

        #expect(decoded.style.fontName == "Helvetica")
        #expect(decoded.style.fontSize == 36)
        #expect(decoded.style.color == .orange)
        #expect(decoded.style.letterSpacing == 0)
        #expect(decoded.style.lineSpacing == 0)
        #expect(decoded.style.stroke == nil)
        #expect(decoded.style.shadow == nil)
        #expect(decoded.style.background == nil)
        #expect(decoded.layout == TextLayout())
        #expect(decoded.animations == TextAnimationSet())
    }

    @Test func animationWindowsClampWithoutBlockingParallelLoop() {
        let animations = TextAnimationSet(
            entrance: TextEntranceAnimationConfiguration(
                presetID: TextAnimationPresetID.Entrance.fade,
                endTime: 3,
                timing: .linear
            ),
            loop: TextLoopAnimationConfiguration(
                presetID: TextAnimationPresetID.Loop.pulse,
                startTime: 0,
                endTime: 5,
                cycleDuration: 2,
                timing: .linear
            ),
            exit: TextExitAnimationConfiguration(
                presetID: TextAnimationPresetID.Exit.fade,
                startTime: 2,
                timing: .linear
            )
        )

        let normalized = animations.normalized(for: 5)
        let entranceSample = TextAnimationEvaluator.sample(
            animations: animations,
            at: 1,
            clipDuration: 5
        )
        let exitSample = TextAnimationEvaluator.sample(
            animations: animations,
            at: 3,
            clipDuration: 5
        )

        #expect(normalized.entrance?.endTime == 2)
        #expect(normalized.exit?.startTime == 2)
        #expect(abs(entranceSample.opacity - 0.5) < 0.0001)
        #expect(abs(entranceSample.scale - 1.08) < 0.0001)
        #expect(abs(exitSample.opacity - (2.0 / 3.0)) < 0.0001)
        #expect(abs(exitSample.scale - 1.08) < 0.0001)
    }

    @Test func catalogAndUnknownPresetRemainDataDrivenAndSafe() {
        #expect(TextAnimationPresetCatalog.definitions(for: .entrance).count == 8)
        #expect(TextAnimationPresetCatalog.definitions(for: .exit).count == 8)
        #expect(TextAnimationPresetCatalog.definitions(for: .loop).count == 8)

        let sample = TextAnimationEvaluator.sample(
            animations: TextAnimationSet(
                entrance: TextEntranceAnimationConfiguration(
                    presetID: "future.custom-preset",
                    endTime: 1
                )
            ),
            at: 0,
            clipDuration: 2
        )
        #expect(sample == TextAnimationSample())
    }

    @Test func customMotionGraphOverridesPresetTimingAndRoundTrips() throws {
        let animations = TextAnimationSet(
            entrance: TextEntranceAnimationConfiguration(
                presetID: TextAnimationPresetID.Entrance.fade,
                endTime: 1,
                timing: .linear,
                customInterpolation: .hold
            )
        )

        let sample = TextAnimationEvaluator.sample(
            animations: animations,
            at: 0.5,
            clipDuration: 2
        )
        let decoded = try JSONDecoder().decode(
            TextAnimationSet.self,
            from: JSONEncoder().encode(animations)
        )

        #expect(sample.opacity == 0)
        #expect(decoded == animations)
    }
}
