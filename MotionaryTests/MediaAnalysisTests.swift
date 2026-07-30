// Focused signal-analysis and source-to-timeline beat mapping tests.

import Foundation
import Testing

@testable import Motionary

struct MediaAnalysisTests {
    @Test func syntheticOneHundredTwentyBPMTrackProducesStableGrid() throws {
        let samples = syntheticBeatSamples(
            beatTimes: (0..<24).map { Double($0) * 0.5 },
            duration: 12
        )

        let analysis = try AudioBeatAnalysisService.analyze(samples: samples)

        #expect(abs(analysis.bpm - 120) < 3)
        #expect(analysis.confidence > 0.5)
        #expect(analysis.markers.count >= 20)

        for expectedTime in stride(from: 0.5, through: 4, by: 0.5) {
            let nearest = analysis.markers
                .map { abs($0.sourceTime - expectedTime) }
                .min() ?? .infinity
            #expect(nearest < 0.025)
        }
    }

    @Test func silentGapsDoNotReceiveInventedGridMarkers() throws {
        let samples = syntheticBeatSamples(
            beatTimes: [0, 0.5, 1, 1.5, 4, 4.5, 5, 5.5, 6, 6.5, 7, 7.5],
            duration: 8
        )

        let analysis = try AudioBeatAnalysisService.analyze(samples: samples)
        let gapMarkers = analysis.markers.filter { $0.sourceTime > 1.85 && $0.sourceTime < 3.85 }

        #expect(analysis.markers.count >= 10)
        #expect(gapMarkers.isEmpty)
    }

    @Test func beatMarkersFollowTrimAndSpeedMappingAndBecomeSnapAnchors() {
        let item = MediaTimelineItem(
            name: "Beat clip",
            mediaID: MediaID(),
            mediaType: .audio,
            timelineStart: 10,
            sourceRange: TimeRangeValue(start: 2, duration: 4),
            speedMap: .constant(speed: 2),
            beatAnalysis: AudioBeatAnalysis(
                bpm: 120,
                confidence: 0.9,
                markers: [
                    AudioBeatMarker(sourceTime: 1.5, strength: 1),
                    AudioBeatMarker(sourceTime: 2.1, strength: 1),
                    AudioBeatMarker(sourceTime: 3, strength: 0.8),
                    AudioBeatMarker(sourceTime: 5, strength: 0.7),
                    AudioBeatMarker(sourceTime: 5.8, strength: 1),
                    AudioBeatMarker(sourceTime: 6.5, strength: 1),
                ],
                sourceFingerprint: "source"
            )
        )
        let project = EditorProject(
            title: "Beat mapping",
            tracks: [
                TimelineTrack(name: "Audio 1", kind: .audio, items: [.media(item)])
            ]
        )

        #expect(item.visibleBeatMarkers.map(\.sourceTime) == [3, 5])
        #expect(item.visibleBeatMarkers.map(\.localTimelineTime) == [0.5, 1.5])
        #expect(project.beatSnapAnchors() == [10.5, 11.5])
        #expect(project.beatSnapAnchors(excluding: item.id).isEmpty)
    }

    @MainActor
    @Test func jumpButtonsNavigateToBeatMarkers() {
        let item = MediaTimelineItem(
            name: "Beat clip",
            mediaID: MediaID(),
            mediaType: .audio,
            timelineStart: 2,
            sourceRange: TimeRangeValue(start: 0, duration: 4),
            beatAnalysis: AudioBeatAnalysis(
                bpm: 120,
                confidence: 0.9,
                markers: [
                    AudioBeatMarker(sourceTime: 1, strength: 0.8),
                    AudioBeatMarker(sourceTime: 2, strength: 0.9),
                ],
                sourceFingerprint: "source"
            )
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(
                editorProject: EditorProject(
                    title: "Beat navigation",
                    tracks: [
                        TimelineTrack(name: "Audio 1", kind: .audio, items: [.media(item)])
                    ]
                )
            )
        )

        viewModel.seek(to: 2)
        viewModel.navigateForward()
        #expect(viewModel.currentTime == 3)
        viewModel.navigateForward()
        #expect(viewModel.currentTime == 4)
        viewModel.navigateBackward()
        #expect(viewModel.currentTime == 3)
    }

    @Test func silenceAndNoiseDoNotCreateMisleadingBeatMarkers() {
        let silence = Array(repeating: Float(0), count: AudioBeatAnalysisService.windowSize * 8)
        var state: UInt64 = 0x1234_5678
        let noise = (0..<110_250).map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Float(Double(state >> 11) / Double(UInt64.max >> 11) * 2 - 1) * 0.2
        }

        for samples in [silence, noise] {
            do {
                _ = try AudioBeatAnalysisService.analyze(samples: samples)
                Issue.record("Expected non-rhythmic audio to be rejected")
            } catch AudioBeatAnalysisError.noReliableBeat {
                // Expected: callers retain the previous analysis on this error.
            } catch {
                Issue.record("Unexpected beat-analysis error: \(error)")
            }
        }
    }

    private func syntheticBeatSamples(beatTimes: [Double], duration: Double) -> [Float] {
        let sampleRate = AudioBeatAnalysisService.sampleRate
        var samples = Array(repeating: Float(0), count: Int(sampleRate * duration))
        for beatTime in beatTimes {
            let start = Int(beatTime * sampleRate)
            for offset in 0..<900 where start + offset < samples.count {
                let envelope = exp(-Double(offset) / 130)
                samples[start + offset] += Float(sin(Double(offset) * 0.21) * envelope)
            }
        }
        return samples
    }
}
