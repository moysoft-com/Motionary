// Keyframe interpolation, migration, editing, trimming, and audio-envelope coverage.

import Foundation
import Testing

@testable import Motionary

struct KeyframeEditingTests {
    @Test func interpolationSupportsLinearHoldAndCubicBezier() async throws {
        let linear = AnimatableProperty(
            baseValue: 0.0,
            keyframes: [
                Keyframe(time: 0, value: 0.0),
                Keyframe(time: 2, value: 1.0)
            ]
        )
        let hold = AnimatableProperty(
            baseValue: 0.0,
            keyframes: [
                Keyframe(time: 0, value: 0.0, interpolation: .hold),
                Keyframe(time: 2, value: 1.0)
            ]
        )
        let eased = AnimatableProperty(
            baseValue: 0.0,
            keyframes: [
                Keyframe(
                    time: 0,
                    value: 0.0,
                    interpolation: KeyframeCurvePreset.easeIn.interpolation
                ),
                Keyframe(time: 2, value: 1.0)
            ]
        )

        #expect(abs(linear.value(at: 1) - 0.5) < 0.0001)
        #expect(hold.value(at: 1.999) == 0)
        #expect(hold.value(at: 2) == 1)
        #expect(eased.value(at: 0.5) < linear.value(at: 0.5))
    }

    @Test func motionPresetsExposeExpectedControlPointsAndOvershoot() async throws {
        #expect(
            KeyframeCurvePreset.fast.interpolation
                == .cubicBezier(
                    control1: KeyframeControlPoint(x: 0.2, y: 0),
                    control2: KeyframeControlPoint(x: 0.2, y: 1)
                )
        )
        #expect(
            KeyframeCurvePreset.anticipate.interpolation
                == .cubicBezier(
                    control1: KeyframeControlPoint(x: 0.36, y: -0.18),
                    control2: KeyframeControlPoint(x: 0.66, y: 1)
                )
        )

        let overshoot = AnimatableProperty(
            baseValue: 0.0,
            keyframes: [
                Keyframe(
                    time: 0,
                    value: 1.0,
                    interpolation: KeyframeCurvePreset.overshoot.interpolation
                ),
                Keyframe(time: 1, value: 2.0)
            ]
        )
        let maximum =
            stride(from: 0.0, through: 1.0, by: 0.01)
            .map { overshoot.value(at: $0) }
            .max() ?? 0
        #expect(maximum > 2)
    }

    @Test func controlPointTimeIsClampedWhileValueCanOvershoot() async throws {
        let point = KeyframeControlPoint(x: 2, y: -1.5)
        #expect(point.x == 1)
        #expect(point.y == -1.5)

        let decoded = try JSONDecoder().decode(
            KeyframeControlPoint.self,
            from: Data(#"{"x":-2,"y":8}"#.utf8)
        )
        #expect(decoded.x == 0)
        #expect(decoded.y == 4)
    }

    @Test func legacyKeyframesDefaultToLinearInterpolation() async throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "id": UUID().uuidString,
                "time": 1.0,
                "value": 0.5
            ]
        )
        let frame = try JSONDecoder().decode(Keyframe<Double>.self, from: data)
        #expect(frame.interpolation == .linear)
    }

    @Test func schemaFourMigratesLegacyStaticVolume() async throws {
        let clip = TimelineClip(
            name: "Legacy volume",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/legacy.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            schemaVersion: 2,
            title: "Legacy",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        let encoded = try JSONEncoder().encode(ProjectContent(editorProject: project))
        var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root["schemaVersion"] = 2
        var editorProject = try #require(root["editorProject"] as? [String: Any])
        editorProject["schemaVersion"] = 2
        var tracks = try #require(editorProject["tracks"] as? [[String: Any]])
        if var items = tracks[0]["items"] as? [[String: Any]] {
            var payload = try #require(items[0]["payload"] as? [String: Any])
            var visuals = try #require(payload["visuals"] as? [String: Any])
            visuals["volume"] = 0.35
            payload["visuals"] = visuals
            items[0]["payload"] = payload
            tracks[0]["items"] = items
        } else {
            var clips = try #require(tracks[0]["clips"] as? [[String: Any]])
            clips[0]["volume"] = 0.35
            tracks[0]["clips"] = clips
        }
        editorProject["tracks"] = tracks
        root["editorProject"] = editorProject

        let legacyData = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(ProjectContent.self, from: legacyData)

        #expect(decoded.schemaVersion == EditorProject.currentSchemaVersion)
        #expect(decoded.editorProject.schemaVersion == EditorProject.currentSchemaVersion)
        #expect(abs(decoded.editorProject.tracks[0].clips[0].volume.baseValue - 0.35) < 0.0001)
        #expect(decoded.editorProject.tracks[0].clips[0].volume.keyframes.isEmpty)
    }

    @Test func schemaFourRoundTripsBezierAndVolumeKeyframes() async throws {
        let volume = AnimatableProperty(
            baseValue: 1.0,
            keyframes: [
                Keyframe(
                    time: 0,
                    value: 0.2,
                    interpolation: KeyframeCurvePreset.easeOut.interpolation
                ),
                Keyframe(time: 2, value: 1.4)
            ]
        )
        let clip = TimelineClip(
            name: "Audio",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/audio.m4a"),
                mediaType: .audio,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2),
            volume: volume
        )
        let content = ProjectContent(
            editorProject: EditorProject(
                title: "Roundtrip",
                tracks: [TimelineTrack(name: "Audio 1", kind: .audio, clips: [clip])]
            )
        )

        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(ProjectContent.self, from: data)
        #expect(decoded == content)
    }

    @Test func cubicSplitPreservesValuesOnBothSides() async throws {
        let property = AnimatableProperty(
            baseValue: 0.0,
            keyframes: [
                Keyframe(
                    time: 0,
                    value: 0.0,
                    interpolation: KeyframeCurvePreset.easeInOut.interpolation
                ),
                Keyframe(time: 10, value: 1.0)
            ]
        )
        let split = property.split(at: 4)

        for time in stride(from: 0.0, through: 4.0, by: 0.25) {
            #expect(abs(split.left.value(at: time) - property.value(at: time)) < 0.0005)
        }
        for time in stride(from: 4.0, through: 10.0, by: 0.25) {
            #expect(abs(split.right.value(at: time - 4) - property.value(at: time)) < 0.0005)
        }
    }

    @MainActor
    @Test func propertyEditsAlwaysCreateAutomaticKeyframes() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Animated",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/animated.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2),
            transform: ClipTransform(
                positionX: AnimatableProperty(
                    baseValue: 0,
                    keyframes: [
                        Keyframe(time: 0, value: 0.0),
                        Keyframe(time: 2, value: 1.0)
                    ]
                )
            )
        )
        let viewModel = makeViewModel(clip: clip)
        defer { viewModel.stop() }
        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)
        viewModel.seek(to: 1)

        viewModel.setSelectedKeyframeValue(0.8, target: .positionX)
        let property = try #require(viewModel.selectedClip?.transform.positionX)
        #expect(property.keyframes.count == 3)
        #expect(
            property.keyframes.contains {
                abs($0.time - 1) < 0.0001 && abs($0.value - 0.8) < 0.0001
            }
        )

        viewModel.undo()
        let undone = viewModel.project.tracks[0].clips[0].transform.positionX
        #expect(undone.keyframes.count == 2)
    }

    @MainActor
    @Test func keyframeTimesSnapToProjectFrames() async throws {
        var project = EditorProject.empty(title: "Snap")
        project.renderSettings.frameRate = 30
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        #expect(abs(viewModel.snappedKeyframeTime(0.051) - (2.0 / 30.0)) < 0.0001)
    }

    @MainActor
    @Test func splitAndTrimRetargetClipLocalKeyframes() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Edit",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/edit.mov"),
                mediaType: .video,
                originalDuration: 4
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4),
            transform: ClipTransform(
                positionX: AnimatableProperty(
                    baseValue: 0,
                    keyframes: [
                        Keyframe(time: 0, value: 0.0),
                        Keyframe(time: 2, value: 1.0),
                        Keyframe(time: 4, value: 0.0)
                    ]
                )
            )
        )
        let viewModel = makeViewModel(clip: clip)
        defer { viewModel.stop() }
        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)
        viewModel.seek(to: 2)
        viewModel.splitSelectedClip()

        let splitClips = viewModel.project.tracks[0].clips.sorted { $0.timelineStart < $1.timelineStart }
        #expect(splitClips.count == 2)
        #expect(splitClips[0].transform.positionX.keyframes.map(\.time) == [0, 2])
        #expect(splitClips[1].transform.positionX.keyframes.map(\.time) == [0, 2])
        #expect(splitClips[1].transform.positionX.keyframes.first?.value == 1)

        let secondID = splitClips[1].id
        viewModel.trimClipStart(secondID, by: 0.5, rebuild: false)
        var trimmed = try #require(viewModel.project.clip(id: secondID))
        #expect(abs(trimmed.transform.positionX.keyframes.first!.time) < 0.0001)
        #expect(abs(trimmed.transform.positionX.keyframes.first!.value - 0.75) < 0.0001)

        viewModel.trimClipEnd(secondID, by: -0.5, rebuild: false)
        trimmed = try #require(viewModel.project.clip(id: secondID))
        #expect(trimmed.transform.positionX.keyframes.allSatisfy { $0.time <= 1.0 + 0.0001 })
        #expect(abs(trimmed.transform.positionX.value(at: 1) - 0.25) < 0.0001)
    }

    @Test func audioEnvelopeSamplerApproximatesBezierAndHoldCurves() async throws {
        let eased = AnimatableProperty(
            baseValue: 0.0,
            keyframes: [
                Keyframe(
                    time: 0,
                    value: 0.0,
                    interpolation: KeyframeCurvePreset.easeInOut.interpolation
                ),
                Keyframe(time: 2, value: 1.0)
            ]
        )
        let held = AnimatableProperty(
            baseValue: 0.0,
            keyframes: [
                Keyframe(time: 0, value: 0.0, interpolation: .hold),
                Keyframe(time: 2, value: 1.0)
            ]
        )

        let easedPoints = AudioEnvelopeSampler.points(for: eased, duration: 2, frameRate: 30)
        let heldPoints = AudioEnvelopeSampler.points(for: held, duration: 2, frameRate: 30)

        #expect(easedPoints.count > 2)
        #expect(heldPoints.count > 2)
        #expect(heldPoints.last?.value == 1)
        #expect(heldPoints.dropLast().last?.value == 0)
        #expect((heldPoints.dropLast().last?.time ?? 0) > 1.9)
    }

    @Test func resolvedTransformUsesCurrentInterpolatedValues() async throws {
        let transform = ClipTransform(
            positionX: AnimatableProperty(
                baseValue: 0,
                keyframes: [
                    Keyframe(time: 0, value: -1.0),
                    Keyframe(time: 2, value: 1.0)
                ]
            ),
            scale: AnimatableScale(
                baseValue: ScaleValue(x: 1, y: 1),
                keyframes: [
                    Keyframe(time: 0, value: ScaleValue(x: 1, y: 1)),
                    Keyframe(time: 2, value: ScaleValue(x: 3, y: 5))
                ]
            )
        )
        let resolved = transform.resolved(at: 1)
        #expect(resolved.positionX.baseValue == 0)
        #expect(resolved.scale.baseValue == ScaleValue(x: 2, y: 3))
    }

    @Test func legacyScalarScaleMigratesToLinkedXYScale() async throws {
        let encoded = try JSONEncoder().encode(ClipTransform())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let legacyScale = AnimatableProperty(
            baseValue: 1.5,
            keyframes: [
                Keyframe(
                    time: 0,
                    value: 1.0,
                    interpolation: KeyframeCurvePreset.easeInOut.interpolation
                ),
                Keyframe(time: 2, value: 3.0)
            ]
        )
        object["scale"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyScale))
        let decoded = try JSONDecoder().decode(
            ClipTransform.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.scale.isLinked)
        #expect(decoded.scale.baseValue == ScaleValue(x: 1.5, y: 1.5))
        #expect(
            decoded.scale.keyframes.map(\.value) == [
                ScaleValue(x: 1, y: 1),
                ScaleValue(x: 3, y: 3)
            ]
        )
    }

    @MainActor
    @Test func linkedScalePreservesRatioAndSplitScaleEditsAxesIndependently() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Scale",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/scale.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2),
            transform: ClipTransform(
                scale: AnimatableScale(
                    baseValue: ScaleValue(x: 2, y: 1),
                    isLinked: true
                )
            )
        )
        let viewModel = makeViewModel(clip: clip)
        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)

        viewModel.setSelectedKeyframeValue(4, target: .scale)
        #expect(viewModel.selectedClip?.transform.scale.baseValue == ScaleValue(x: 4, y: 2))

        viewModel.setScaleLinked(false)
        viewModel.setSelectedKeyframeValue(3, target: .scaleY)
        #expect(viewModel.selectedClip?.transform.scale.baseValue == ScaleValue(x: 4, y: 3))
    }

    @Test func scaleBezierSplitPreservesBothAxes() async throws {
        let scale = AnimatableScale(
            baseValue: ScaleValue(),
            keyframes: [
                Keyframe(
                    time: 0,
                    value: ScaleValue(x: 1, y: 2),
                    interpolation: KeyframeCurvePreset.easeInOut.interpolation
                ),
                Keyframe(time: 4, value: ScaleValue(x: 5, y: 10))
            ],
            isLinked: false
        )
        let split = scale.split(at: 1.5)

        for time in stride(from: 0.0, through: 1.5, by: 0.15) {
            let expected = scale.value(at: time)
            let actual = split.left.value(at: time)
            #expect(abs(actual.x - expected.x) < 0.001)
            #expect(abs(actual.y - expected.y) < 0.001)
        }
        for time in stride(from: 1.5, through: 4.0, by: 0.15) {
            let expected = scale.value(at: time)
            let actual = split.right.value(at: time - 1.5)
            #expect(abs(actual.x - expected.x) < 0.001)
            #expect(abs(actual.y - expected.y) < 0.001)
        }
    }

    @MainActor
    @Test func navigationAndGraphSegmentUseSelectedClipKeyframesWithoutWrapping() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Navigation",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/navigation.mov"),
                mediaType: .video,
                originalDuration: 4
            ),
            timelineStart: 2,
            sourceRange: TimeRangeValue(start: 0, duration: 4),
            transform: ClipTransform(
                positionX: AnimatableProperty(
                    baseValue: 0,
                    keyframes: [
                        Keyframe(time: 0.5, value: 0),
                        Keyframe(time: 2, value: 1),
                        Keyframe(time: 3.5, value: 0)
                    ]
                )
            )
        )
        let viewModel = makeViewModel(clip: clip)
        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)
        viewModel.activeKeyframeTarget = .positionX
        viewModel.seek(to: 4)

        #expect(viewModel.navigationPoints == [2, 2.5, 4, 5.5, 6])
        #expect(viewModel.candidateGraphSegment(in: .transform)?.startTime == 2)
        #expect(viewModel.candidateGraphSegment(in: .transform)?.endTime == 3.5)

        viewModel.seek(to: 2)
        #expect(!viewModel.canNavigateBackward)
        viewModel.navigateBackward()
        #expect(viewModel.currentTime == 2)

        viewModel.seek(to: 6)
        #expect(!viewModel.canNavigateForward)
        viewModel.navigateForward()
        #expect(viewModel.currentTime == 6)
    }

    @MainActor
    @Test func sectionKeyframesCreateRemoveAndStaySynchronized() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Section keyframes",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/section.mov"),
                mediaType: .video,
                originalDuration: 3
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 3)
        )
        let viewModel = makeViewModel(clip: clip)
        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)

        viewModel.seek(to: 0)
        viewModel.toggleKeyframeSection(.transform)
        viewModel.seek(to: 2)
        viewModel.toggleKeyframeSection(.transform)
        viewModel.seek(to: 1)
        viewModel.setSelectedKeyframeValue(0.5, target: .positionX)

        let edited = try #require(viewModel.selectedClip)
        for target in edited.keyframeTargets(in: .transform) {
            let times = try #require(
                edited.animatableProperty(for: target)?.keyframes.map(\.time)
            )
            #expect(times == [0, 1, 2])
        }

        viewModel.toggleKeyframeSection(.transform)
        let removed = try #require(viewModel.selectedClip)
        for target in removed.keyframeTargets(in: .transform) {
            let times = try #require(
                removed.animatableProperty(for: target)?.keyframes.map(\.time)
            )
            #expect(times == [0, 2])
        }
    }

    @MainActor
    @Test func graphSelectionFollowsPlayheadWithinActiveSection() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Graph selection",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/graphs.mov"),
                mediaType: .image,
                originalDuration: 4
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4),
            transform: ClipTransform(
                positionY: AnimatableProperty(
                    baseValue: 0,
                    keyframes: [
                        Keyframe(time: 0, value: 0),
                        Keyframe(time: 2, value: 1),
                        Keyframe(time: 4, value: 0),
                    ]
                )
            )
        )
        let viewModel = makeViewModel(clip: clip)
        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)
        viewModel.activeKeyframeTarget = .positionY

        viewModel.seek(to: 1)
        viewModel.selectGraphSegment(atPlayheadIn: .transform)
        #expect(viewModel.graphSegment?.section == .transform)
        #expect(viewModel.graphSegment?.startTime == 0)
        #expect(viewModel.graphSegment?.endTime == 2)

        viewModel.seek(to: 3)
        viewModel.selectGraphSegment(atPlayheadIn: .transform)
        #expect(viewModel.graphSegment?.startTime == 2)
        #expect(viewModel.graphSegment?.endTime == 4)

        viewModel.seek(to: 4)
        viewModel.selectGraphSegment(atPlayheadIn: .transform)
        #expect(viewModel.graphSegment == nil)
        #expect(viewModel.displayedGraphSegment?.startTime == 2)
        #expect(viewModel.displayedGraphSegment?.endTime == 4)
    }

    @MainActor
    @Test func graphInterpolationAppliesToEveryPropertyInSection() async throws {
        let clipID = UUID()
        let frames = [
            Keyframe(time: 0, value: 0.0),
            Keyframe(time: 2, value: 1.0),
        ]
        let clip = TimelineClip(
            id: clipID,
            name: "Section graph",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/section-graph.mov"),
                mediaType: .image,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2),
            transform: ClipTransform(
                positionX: AnimatableProperty(baseValue: 0, keyframes: frames),
                positionY: AnimatableProperty(baseValue: 0, keyframes: frames),
                rotationDegrees: AnimatableProperty(baseValue: 0, keyframes: frames)
            )
        )
        let viewModel = makeViewModel(clip: clip)
        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)

        viewModel.setInterpolation(
            KeyframeCurvePreset.easeInOut.interpolation,
            section: .transform,
            startTime: 0
        )

        let edited = try #require(viewModel.selectedClip)
        for target in [KeyframeTarget.positionX, .positionY, .rotation] {
            let interpolation = try #require(
                edited.animatableProperty(for: target)?.keyframes.first?.interpolation
            )
            #expect(interpolation == KeyframeCurvePreset.easeInOut.interpolation)
        }
    }

    @MainActor
    private func makeViewModel(clip: TimelineClip) -> EditorViewModel {
        EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(
                editorProject: EditorProject(
                    title: "Keyframes",
                    tracks: [
                        TimelineTrack(
                            name: clip.mediaType == .audio ? "Audio 1" : "Layer 1",
                            kind: clip.requiredTrackKind,
                            clips: [clip]
                        )
                    ]
                )
            )
        )
    }
}
