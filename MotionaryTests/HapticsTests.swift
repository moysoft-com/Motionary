import AVFoundation
import CoreHaptics
import Foundation
import UIKit
import XCTest
@testable import Motionary

final class HapticsTests: XCTestCase {
    @MainActor
    func testVideoHapticsRecoverFromStartAndSchedulingFailuresWithoutReattaching() async {
        let rescheduled = expectation(description: "The replacement engine receives the haptic event")
        let startFailure = PlaybackTestHapticEngine(startError: CHHapticError(.engineStartTimeout))
        let stoppedEngine = PlaybackTestHapticEngine {
            throw CHHapticError(.engineNotRunning)
        }
        let recoveredEngine = PlaybackTestHapticEngine {
            rescheduled.fulfill()
            throw CHHapticError(.invalidPatternData)
        }
        var engines = [startFailure, stoppedEngine, recoveredEngine]
        let playback = HapticPlayback(makeEngine: { engines.isEmpty ? nil : engines.removeFirst() })
        let video = HapticTestVideoClock()
        defer { withExtendedLifetime(video) { playback.detach() } }

        playback.attach(to: video, track: HapticTrack(events: [
            .init(time: 0, duration: 0, samples: [.init(time: 0, intensity: 1, sharpness: 0.5)]),
        ]))

        await fulfillment(of: [rescheduled], timeout: 2)
        XCTAssertTrue(stoppedEngine.didStop)
        XCTAssertTrue(engines.isEmpty)
    }

    func testBeatHapticsArrangeMusicalAccentsAndFadeWithinTheRetimedClip() throws {
        var light = AudioBeatMarker(sourceTime: 1, strength: 0.99)
        light.accentScore = 0.45
        var downbeat = AudioBeatMarker(sourceTime: 1.5, strength: 0.1, isDownbeat: true)
        downbeat.accentScore = 0.8
        var quiet = AudioBeatMarker(sourceTime: 2, strength: 1)
        quiet.accentScore = 0.12
        var breakStart = AudioBeatMarker(sourceTime: 2.5, strength: 0.9)
        breakStart.accentScore = 0.85
        breakStart.isBreakStart = true
        var drop = AudioBeatMarker(sourceTime: 3, strength: 0.2, isDownbeat: true)
        drop.accentScore = 0.9
        drop.isDrop = true
        let clip = MediaTimelineItem(
            name: "Music", mediaID: MediaID(), mediaType: .audio, timelineStart: 4,
            sourceRange: .init(start: 1, duration: 2.25), speedMap: .constant(speed: 2),
            beatAnalysis: .init(
                bpm: 120, confidence: 0.8,
                markers: [.init(sourceTime: 0.5, strength: 1), light, downbeat, quiet, breakStart, drop,
                          .init(sourceTime: 3.25, strength: 1)],
                subbeats: [.init(sourceTime: 1.25, division: 2, position: 1, onsetTime: nil)],
                subbeatDivision: 2, sourceFingerprint: "music"
            )
        )
        let clips = BeatHapticArrangement.makeClips(for: clip, around: [])
        XCTAssertEqual(clips.map(\.timelineStart), [4, 4.25, 5])
        let accent = try XCTUnwrap(clips.first { $0.timelineStart == 4.25 })
        let impact = try XCTUnwrap(clips.last)
        let pulse = try XCTUnwrap(clips.first)
        XCTAssertGreaterThan(accent.intensity.baseValue, pulse.intensity.baseValue)
        XCTAssertGreaterThan(accent.duration, pulse.duration)
        XCTAssertGreaterThan(impact.intensity.baseValue, accent.intensity.baseValue)
        XCTAssertLessThan(impact.sharpness.baseValue, accent.sharpness.baseValue)
        XCTAssertLessThanOrEqual(impact.timelineEnd, clip.timelineEnd)
        let rendered = try HapticTrack.render(clips, through: clip.timelineEnd)
        XCTAssertEqual(rendered.events.count, clips.count)
        for event in rendered.events {
            XCTAssertEqual(try XCTUnwrap(event.samples.last).intensity, 0, accuracy: 0.0001)
        }
    }

    func testBeatHapticsPrioritizeDenseAccentsAndLeaveRoomBetweenPulses() throws {
        let clip = MediaTimelineItem(
            name: "Fast music", mediaID: MediaID(), mediaType: .audio, timelineStart: 0,
            sourceRange: .init(start: 0, duration: 2), speedMap: .constant(speed: 4),
            beatAnalysis: .init(
                bpm: 160, confidence: 0.8,
                markers: [
                    .init(sourceTime: 0, strength: 0.6),
                    .init(sourceTime: 0.375, strength: 0.95),
                    .init(sourceTime: 0.75, strength: 0.7),
                    .init(sourceTime: 1.125, strength: 0.5),
                    .init(sourceTime: 1.5, strength: 0.05),
                ],
                method: .signalFallback, sourceFingerprint: "music"
            )
        )
        let clips = BeatHapticArrangement.makeClips(for: clip, around: [])
        XCTAssertEqual(clips.map(\.timelineStart), [0.09375, 0.28125])
        let first = try XCTUnwrap(clips.first)
        XCTAssertLessThanOrEqual(first.duration, (0.28125 - 0.09375) * 0.55)
    }

    func testOffbeatAccentsRoundTripAndCreateSoftHapticsWithoutTimelineMarkers() throws {
        let analysis = AudioBeatAnalysis(
            bpm: 60, confidence: 0.9,
            markers: [1.0, 2.0, 3.0].map { .init(sourceTime: $0, strength: 0.9, isDownbeat: true) },
            offbeatAccents: [.init(sourceTime: 1.1, strength: 1), .init(sourceTime: 1.5, strength: 0.85)],
            sourceFingerprint: "music"
        )
        let restored = try JSONDecoder().decode(AudioBeatAnalysis.self, from: JSONEncoder().encode(analysis))
        XCTAssertEqual(restored, analysis)
        let clip = MediaTimelineItem(
            name: "Music", mediaID: MediaID(), mediaType: .audio, timelineStart: 2,
            sourceRange: .init(start: 0.5, duration: 3), speedMap: .constant(speed: 2), beatAnalysis: restored
        )
        XCTAssertEqual(clip.visibleBeatMarkers.map(\.sourceTime), [1, 2, 3])
        let clips = BeatHapticArrangement.makeClips(for: clip, around: [])
        XCTAssertEqual(clips.map(\.timelineStart), [2.25, 2.5, 2.75, 3.25])
        XCTAssertLessThan(clips[1].intensity.baseValue, clips[0].intensity.baseValue)
        XCTAssertLessThan(clips[1].sharpness.baseValue, clips[0].sharpness.baseValue)
        XCTAssertLessThan(clips[1].duration, clips[0].duration)
    }

    @MainActor
    func testAddBeatHapticsKeepsExistingClipsAndUndoesTheBatchInOneStep() throws {
        let clip = MediaTimelineItem(
            name: "Music", mediaID: MediaID(), mediaType: .audio, timelineStart: 0,
            sourceRange: .init(start: 0, duration: 2),
            beatAnalysis: .init(
                bpm: 120, confidence: 0.8,
                markers: [0, 0.5, 1, 1.5].map { .init(sourceTime: $0, strength: 0.8) },
                method: .signalFallback, sourceFingerprint: "music"
            )
        )
        let manual = HapticTimelineItem(timelineStart: 0.5, duration: 0.2, style: .impact)
        let audioTrack = TimelineTrack(name: "Audio", kind: .audio, items: [.media(clip)])
        let lockedTrack = TimelineTrack(name: "Haptics", kind: .haptic, items: [.haptic(manual)], isLocked: true)
        let project = EditorProject(title: "Beat haptics", tracks: [lockedTrack, audioTrack])
        let editor = EditorViewModel(
            projectID: UUID(), projectStore: ProjectStore(), initialContent: .init(editorProject: project)
        )
        editor.selectTimelineItem(clip.id, trackID: audioTrack.id)
        editor.addHapticsFromSelectedBeats()
        XCTAssertEqual(editor.project.audibleHapticItems.map(\.timelineStart).sorted(), [0, 0.5, 1, 1.5])
        XCTAssertEqual(editor.project.item(id: manual.id), .haptic(manual))
        XCTAssertEqual(editor.selectedTimelineItemID, clip.id)
        let added = editor.project.tracks
        editor.addHapticsFromSelectedBeats()
        XCTAssertEqual(editor.project.tracks, added)
        editor.undo()
        XCTAssertEqual(editor.project.audibleHapticItems, [manual])
        editor.redo()
        XCTAssertEqual(editor.project.audibleHapticItems.map(\.timelineStart).sorted(), [0, 0.5, 1, 1.5])
    }

    func testProjectArchivePreservesEditableHapticPatternAndKeyframes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var haptic = HapticTimelineItem(timelineStart: 0.7, duration: 2, style: .pattern)
        haptic.patternSteps = [.init(), .init(position: 0.35, length: 0.45, strength: 0.65)]
        haptic.sharpness = .init(baseValue: 0.2, keyframes: [.init(time: 1, value: 0.8, interpolation: .hold)])
        var editor = EditorProject.empty(title: "Haptic project")
        editor.tracks.append(TimelineTrack(name: "Haptics 1", kind: .haptic, items: [.haptic(haptic)]))

        let package = try ProjectArchive.export(
            project: Project(title: editor.title),
            content: ProjectContent(editorProject: editor),
            folder: root
        )
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        let imported = try ProjectArchive.extract(
            url: package, to: root.appendingPathComponent("imported"), projectID: UUID()
        ).editorProject
        XCTAssertEqual(imported.item(id: haptic.id), .haptic(haptic))
        XCTAssertEqual(imported.audibleHapticItems, [haptic])
        XCTAssertTrue(imported.containsHaptics)
    }

    func testSplitPreservesEnvelopeAndAutomationAndDoesNotRestartThePattern() throws {
        var rumble = HapticTimelineItem(timelineStart: 0, duration: 2, style: .rumble)
        rumble.attack = 0.8
        rumble.release = 0.8
        rumble.sharpness = .init(baseValue: 0, keyframes: [.init(time: 0, value: 0), .init(time: 2, value: 1)])
        let split = try XCTUnwrap(TimelineItem.haptic(rumble).split(at: 0.5))
        guard case .haptic(let left) = split.left, case .haptic(let right) = split.right else {
            XCTFail("Both split items should be haptic")
            return
        }
        let original = try HapticTrack.render([rumble], through: 2)
        let result = try HapticTrack.render([left, right], through: 2)
        XCTAssertEqual(result.events.map(\.time), [0, 0.5])
        let expected = original.events[0].sample(at: 0.5)
        let afterSplit = result.events[1].sample(at: 0)
        XCTAssertEqual(expected.intensity, afterSplit.intensity, accuracy: 0.001)
        XCTAssertEqual(expected.sharpness, afterSplit.sharpness, accuracy: 0.001)

        let pulse = HapticTimelineItem(timelineStart: 0, duration: 2, style: .pulse, period: 0.5)
        let edited = TimelineItem.haptic(pulse).trimmingStart(by: 0.2)
        guard case .haptic(let trimmed) = edited else { return XCTFail("Expected a haptic clip") }
        XCTAssertEqual(try HapticTrack.render([trimmed], through: 2).events.map(\.time), [0.5, 1, 1.5])
    }

    func testPatternKeepsKeyframesAndCyclePhaseAcrossTrims() throws {
        var item = HapticTimelineItem(
            timelineStart: 1, duration: 2, style: .rumble, period: 0.5,
            patternEnabled: true, pulseLength: 0.2
        )
        item.intensity = .init(baseValue: 0, keyframes: [.init(time: 0, value: 0), .init(time: 2, value: 1)])
        item.sharpness = .init(baseValue: 1, keyframes: [.init(time: 0, value: 1), .init(time: 2, value: 0)])
        let trimmed = TimelineItem.haptic(item).trimmingStart(by: 0.125)
        guard case .haptic(let clip) = trimmed else { return XCTFail("Expected a haptic clip") }
        let events = try HapticTrack.render([clip], through: 3).events
        XCTAssertEqual(events.map(\.time), [1.125, 1.5, 2, 2.5])
        XCTAssertEqual(try XCTUnwrap(events.first).duration, 0.075, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(events[1].samples.first).intensity, 0.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(events[1].samples.first).sharpness, 0.75, accuracy: 0.001)
        XCTAssertEqual(try JSONDecoder().decode(HapticTimelineItem.self, from: JSONEncoder().encode(clip)), clip)

        item.pulseLength = 0
        XCTAssertEqual(try HapticTrack.render([item], through: 3).events.map(\.duration), [0, 0, 0, 0])
        item.patternEnabled = false
        XCTAssertEqual(try HapticTrack.render([item], through: 3).events.map(\.duration), [2])
    }

    @MainActor
    func testPatternTimingKeyframesDrivePulsesAndSurviveProjectRoundTrip() throws {
        let item = HapticTimelineItem(
            timelineStart: 0, duration: 1, style: .rumble, period: 0.5,
            patternEnabled: true, pulseLength: 0
        )
        let track = TimelineTrack(name: "Haptics", kind: .haptic, items: [.haptic(item)])
        let editor = EditorViewModel(
            projectID: UUID(), projectStore: ProjectStore(), initialContent: ProjectContent(
                editorProject: EditorProject(title: "Pattern timing", tracks: [track])
            )
        )
        editor.selectTimelineItem(item.id, trackID: track.id)
        editor.toggleKeyframeSection(.haptics)
        editor.setInterpolation(.hold, section: .haptics, startTime: 0)
        editor.updateCurrentTime(0.5)
        editor.setSelectedKeyframeValue(0.10, target: .hapticRepeat)
        let revision = editor.timelineContentRevision
        editor.setSelectedKeyframeValue(0.04, target: .hapticLength, interactive: true)
        XCTAssertGreaterThan(editor.timelineContentRevision, revision)
        editor.finishInteractiveEdit(rebuild: false)
        guard case .haptic(let updated) = editor.project.item(id: item.id) else {
            return XCTFail("Expected a haptic clip")
        }

        let decoded = try JSONDecoder().decode(HapticTimelineItem.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(decoded, updated)
        let events = try HapticTrack.render([decoded], through: 1).events
        XCTAssertEqual(events.count, 6)
        XCTAssertEqual(events.first?.duration, 0)
        for (index, event) in events.dropFirst().enumerated() {
            XCTAssertEqual(event.time, 0.5 + Double(index) * 0.10, accuracy: 0.0001)
            XCTAssertEqual(event.duration, 0.04, accuracy: 0.0001)
        }
    }

    @MainActor
    func testHapticsReuseEmptyAndCompatibleTracksBeforeAddingATopLayer() throws {
        let existing = HapticTimelineItem(timelineStart: 0, duration: 0.5, style: .rumble)
        let available = TimelineTrack(name: "Haptics", kind: .haptic, items: [.haptic(existing)])
        let empty = TimelineTrack(name: "Layer", kind: .undefined)
        let anchor = HapticTimelineItem(timelineStart: 0, duration: 8, style: .rumble)
        let locked = TimelineTrack(name: "Locked", kind: .haptic, items: [.haptic(anchor)], isLocked: true)
        let editor = EditorViewModel(
            projectID: UUID(), projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: EditorProject(title: "Timeline", tracks: [available, empty, locked]))
        )
        let first = try XCTUnwrap(editor.addHaptic())
        XCTAssertEqual(editor.project.tracks[1].id, empty.id)
        XCTAssertEqual(editor.project.tracks[1].kind, .haptic)
        XCTAssertEqual(editor.project.tracks[1].items.map(\.id), [first])
        guard case .haptic(let clip) = editor.project.item(id: first) else { return XCTFail("Expected a haptic clip") }
        XCTAssertFalse(clip.isPatternEnabled)
        XCTAssertEqual(clip.duration, 2)

        editor.updateCurrentTime(2)
        let second = try XCTUnwrap(editor.addHaptic())
        XCTAssertEqual(editor.project.tracks[0].items.map(\.id), [existing.id, second])
        editor.updateCurrentTime(0)
        let third = try XCTUnwrap(editor.addHaptic())
        XCTAssertEqual(editor.project.tracks.first?.items.map(\.id), [third])
        XCTAssertEqual(editor.project.tracks.last?.items.map(\.id), [anchor.id])
    }

    @MainActor
    func testHapticWorkspaceKeyframesUseClipLocalTimeAndSharedGraph() throws {
        let haptic = HapticTimelineItem(timelineStart: 1, duration: 2, sourceStart: 0.5, style: .rumble)
        let track = TimelineTrack(name: "Haptics", kind: .haptic, items: [.haptic(haptic)])
        let editor = EditorViewModel(
            projectID: UUID(), projectStore: ProjectStore(), initialContent: ProjectContent(
                editorProject: EditorProject(title: "Haptic keyframes", tracks: [track])
            )
        )
        editor.selectTimelineItem(haptic.id, trackID: track.id)
        editor.updateCurrentTime(1)
        editor.toggleKeyframeSection(.haptics)
        editor.updateCurrentTime(2)
        editor.toggleKeyframeSection(.haptics)
        editor.setSelectedKeyframeValue(0.3, target: .hapticIntensity)
        editor.openCandidateGraphSegment(in: .haptics)
        XCTAssertEqual(editor.graphSegment?.startTime, 0)
        XCTAssertEqual(editor.graphSegment?.endTime, 1)
        editor.setInterpolation(.hold, section: .haptics, startTime: 0)

        XCTAssertTrue(editor.moveTimelineKeyframes(itemID: haptic.id, section: .haptics, effectID: nil, from: 1, to: 1.3))
        guard case .haptic(let updated) = editor.project.item(id: haptic.id) else {
            return XCTFail("Expected a haptic clip")
        }
        XCTAssertEqual(updated.intensity.keyframes.map(\.time), [0.5, 1.8])
        XCTAssertEqual(updated.sharpness.keyframes.map(\.time), [0.5, 1.8])
        XCTAssertEqual(updated.intensity.keyframes.last?.value, 0.3)
        XCTAssertEqual(updated.intensity.keyframes.first?.interpolation, .hold)
    }

    @MainActor
    func testEditorExportsMotionaryVideoFromTheTimeline() async throws {
        let sourceURL = try XCTUnwrap(Bundle.main.url(forResource: "RecommendedAnimation", withExtension: "mp4"))
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        let source = ClipSource(url: sourceURL, mediaType: .video, originalDuration: duration)
        let clip = TimelineClip(
            name: "Export sample", source: source, timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 0.5)
        )
        let impact = HapticTimelineItem(timelineStart: 0.2, duration: 0.1, style: .impact)
        let settings = VideoExportSettings(
            width: 160, height: 160, frameRate: 24, videoBitrate: 500_000, audioBitrate: 96_000,
            codec: .h264, container: .mp4, watermarkEnabled: false
        )
        let project = EditorProject(
            title: "Haptic render", renderSettings: RenderSettings(width: 160, height: 160, frameRate: 24),
            exportSettings: settings,
            tracks: [
                TimelineTrack(name: "Video", kind: .visual, clips: [clip]),
                TimelineTrack(name: "Haptics", kind: .haptic, items: [.haptic(impact)]),
            ]
        )
        let editor = EditorViewModel(
            projectID: project.id, projectStore: ProjectStore(), initialContent: ProjectContent(editorProject: project)
        )

        editor.exportProject(settings: settings, includeHaptics: true)
        await editor.exportTask?.value
        XCTAssertNil(editor.errorMessage)
        let url = try XCTUnwrap(editor.exportedVideoURL)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        struct PosterHeader: Decodable {
            let posterJPEG: Data
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try MotionaryVideoContainer.readHeader(PosterHeader.self, from: file)
        let poster = try XCTUnwrap(UIImage(data: header.posterJPEG)?.cgImage)
        XCTAssertEqual(poster.width, 160)
        XCTAssertEqual(poster.height, 160)
        let movie = try await MotionaryVideoArchive.open(url)
        defer { movie.removeTemporaryFiles() }
        XCTAssertEqual(movie.title, "Haptic render")
        XCTAssertEqual(movie.haptics.events.map(\.time), [0.2])
        let output = AVURLAsset(url: movie.url)
        let outputDuration = try await output.load(.duration).seconds
        XCTAssertEqual(outputDuration, 0.5, accuracy: 0.05)
    }

    func testMotionaryVideoRetainsMovieBytesAndOnlyRenderedHaptics() async throws {
        let source = try XCTUnwrap(Bundle.main.url(forResource: "RecommendedAnimation", withExtension: "mp4"))
        let impact = HapticTimelineItem(timelineStart: 0, duration: 0.1, style: .impact)
        let expected = try HapticTrack.render([impact], through: 0.1)
        let file = try MotionaryVideoArchive.write(movie: source, title: "With haptics", haptics: expected)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let result = try await MotionaryVideoArchive.open(file)
        defer { result.removeTemporaryFiles() }
        XCTAssertEqual(result.haptics, expected)
        XCTAssertEqual(result.title, "With haptics")
        XCTAssertEqual(try Data(contentsOf: result.url), try Data(contentsOf: source))
        XCTAssertEqual(file.pathExtension, "motionaryvideo")

        let handle = try FileHandle(forWritingTo: file)
        let length = try handle.seekToEnd()
        try handle.truncate(atOffset: length - 1)
        try handle.close()
        do {
            _ = try await MotionaryVideoArchive.open(file)
            XCTFail("A truncated video should be rejected")
        } catch MotionaryVideoArchive.ArchiveError.invalid {
            // Expected.
        }
    }
}


private final class HapticTestVideoClock: AVPlayer {
    override var timeControlStatus: AVPlayer.TimeControlStatus { .playing }
    override var rate: Float {
        get { 1 }
        set {}
    }

    override func currentTime() -> CMTime { .zero }
}

private final class PlaybackTestHapticEngine: HapticPlaybackEngine {
    var currentTime: TimeInterval { 0 }
    var playsHapticsOnly = false
    var stoppedHandler: CHHapticEngine.StoppedHandler = { _ in }
    var resetHandler: CHHapticEngine.ResetHandler = {}
    private(set) var didStop = false
    private let startError: Error?
    private let makePlayer: () throws -> any CHHapticAdvancedPatternPlayer

    init(
        startError: Error? = nil,
        makePlayer: @escaping () throws -> any CHHapticAdvancedPatternPlayer = {
            throw CHHapticError(.invalidPatternData)
        }
    ) {
        self.startError = startError
        self.makePlayer = makePlayer
    }

    func start() throws {
        if let startError { throw startError }
    }

    func stopPlayback() {
        didStop = true
    }

    func makeAdvancedPlayer(with pattern: CHHapticPattern) throws -> any CHHapticAdvancedPatternPlayer {
        try makePlayer()
    }
}

final class TimelineAudioWaveformTests: XCTestCase {
    func testScalingKeepsDetailInLoudAndQuietClips() {
        let loud = TimelineAudioWaveformLoader.scaledEnvelope([0, 0.50, 0.65, 0.90, 1])
        let quiet = TimelineAudioWaveformLoader.scaledEnvelope([0, 0.010, 0.013, 0.018, 0.020])
        XCTAssertEqual(loud[0], 0.015)
        XCTAssertGreaterThan(loud[2] - loud[1], 0.10)
        XCTAssertLessThan(loud[4], 1)
        for (left, right) in zip(loud, quiet) {
            XCTAssertEqual(left, right, accuracy: 0.001)
        }
    }
}
