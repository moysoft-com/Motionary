// Focused signal-analysis and source-to-timeline beat mapping tests.

import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
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

    @Test func selectedSubdivisionsMapThroughTrimAndSpeed() throws {
        let analysis = AudioBeatAnalysis(
            bpm: 120, confidence: 0.8,
            markers: [AudioBeatMarker(sourceTime: 1, strength: 1), AudioBeatMarker(sourceTime: 2, strength: 1)],
            subbeats: [AudioSubbeat(sourceTime: 1.25, division: 4, position: 1, onsetTime: nil),
                       AudioSubbeat(sourceTime: 1.5, division: 2, position: 1, onsetTime: nil),
                       AudioSubbeat(sourceTime: 1.75, division: 4, position: 3, onsetTime: nil)],
            subbeatDivision: 4, sourceFingerprint: "source")
        let restored = try JSONDecoder().decode(AudioBeatAnalysis.self, from: JSONEncoder().encode(analysis))
        #expect(restored == analysis)
        var item = MediaTimelineItem(name: "beat", mediaID: MediaID(), mediaType: .audio,
                                     timelineStart: 2, sourceRange: TimeRangeValue(start: 0.5, duration: 3),
                                     speedMap: .constant(speed: 2), beatAnalysis: restored)
        #expect(item.visibleBeatMarkers.map(\.sourceTime) == [1, 1.25, 1.5, 1.75, 2])
        #expect(item.visibleBeatMarkers.map(\.localTimelineTime) == [0.25, 0.375, 0.5, 0.625, 0.75])
        item.beatAnalysis?.subbeatDivision = 0
        #expect(item.visibleBeatMarkers.map(\.sourceTime) == [1, 2])
    }

    @MainActor
    @Test func subdivisionSelectionIsUndoable() throws {
        let item = MediaTimelineItem(name: "beat", mediaID: MediaID(), mediaType: .audio,
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 4),
            beatAnalysis: AudioBeatAnalysis(bpm: 120, confidence: 0.8,
                markers: [AudioBeatMarker(sourceTime: 1, strength: 1)],
                subbeats: [AudioSubbeat(sourceTime: 1.5, division: 2, position: 1, onsetTime: nil)],
                sourceFingerprint: "source"))
        let project = EditorProject(title: "Subbeats", tracks: [TimelineTrack(name: "Audio", kind: .audio, items: [.media(item)])])
        let viewModel = EditorViewModel(projectID: UUID(), projectStore: ProjectStore(),
                                        initialContent: ProjectContent(editorProject: project))
        viewModel.selectTimelineItem(item.id, trackID: project.tracks[0].id)
        viewModel.setSelectedBeatSubdivision(2)
        guard case .media(let updated) = try #require(viewModel.project.item(id: item.id)) else {
            Issue.record("Expected audio item")
            return
        }
        #expect(updated.beatAnalysis?.subbeatDivision == 2)
        #expect(updated.visibleBeatMarkers.map(\.sourceTime) == [1, 1.5])
        viewModel.undo()
        guard case .media(let restored) = try #require(viewModel.project.item(id: item.id)) else {
            Issue.record("Expected audio item")
            return
        }
        #expect(restored.beatAnalysis?.subbeatDivision == 0)
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

    @Test func legacyBackgroundSettingsDecodeAsAutomatic() throws {
        let settings = try JSONDecoder().decode(BackgroundRemovalSettings.self,
            from: Data(#"{"edgeRefinement":0.2,"feather":0.35}"#.utf8))
        #expect(settings.mode == .automatic)
        #expect(settings.requiresForegroundMatte)
        #expect(settings.strokes.isEmpty)
        #expect(settings.feather == 0.35)
    }

    @Test func customCutoutSettingsRoundTrip() throws {
        let settings = BackgroundRemovalSettings(mode: .custom, isInverted: true, strokes: [
            BackgroundBrushStroke(points: [BackgroundBrushPoint(x: 0.25, y: 0.75)], diameter: 0.2, restores: false)
        ])
        let decoded = try JSONDecoder().decode(BackgroundRemovalSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(!decoded.requiresForegroundMatte)
    }

    @Test func stillBackgroundRemovalWritesReadableReusablePNGMatte() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.png")
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        try context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let artifact = try await BackgroundRemovalService(segmenter: HalfForegroundSegmenter()).generateMatte(
            sourceURL: url, sourceRange: TimeRangeValue(start: 2, duration: 5),
            destinationURL: directory.appendingPathComponent("matte.mov"))
        #expect(artifact.url.pathExtension == "png")
        #expect(artifact.covers(TimeRangeValue(start: 0, duration: 100)))
        let matte = try #require(CIImage(contentsOf: artifact.url))
        let result = BackgroundRemovalImageRenderer.apply(BackgroundRemovalSettings(),
            matte: matte.applyingFilter("CIMaskToAlpha"), to: image)
        #expect(alpha(result, x: 8, y: 16) > 240)
        #expect(alpha(result, x: 56, y: 16) < 10)
    }

    @Test func chromaKeyPreservesForegroundAndSourceTransparency() {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 32)
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: extent)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 0.5))
            .cropped(to: CGRect(x: 32, y: 0, width: 32, height: 32))
        let source = red.composited(over: CIImage(color: .clear).cropped(to: extent))
            .composited(over: green.cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32)))
        let settings = BackgroundRemovalSettings(mode: .chromaKey)
        let result = BackgroundRemovalImageRenderer.apply(settings, matte: nil, to: source)
        #expect(alpha(result, x: 8, y: 16) < 10)
        #expect(abs(Int(alpha(result, x: 56, y: 16)) - 128) < 5)
        #expect(BackgroundRemovalImageRenderer.keyAlpha(red: 0, green: 1, blue: 0, settings: settings) == 0)
        #expect(BackgroundRemovalImageRenderer.keyAlpha(red: 1, green: 0, blue: 0, settings: settings) == 1)
    }

    @Test func customBrushErasesRestoresAndInvertsAtNormalizedCoordinates() {
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let point = BackgroundBrushPoint(x: 0.25, y: 0.25)
        var settings = BackgroundRemovalSettings(mode: .custom, strokes: [
            BackgroundBrushStroke(points: [point], diameter: 0.3, restores: false)
        ])
        let erased = BackgroundRemovalImageRenderer.apply(settings, matte: nil, to: image)
        #expect(alpha(erased, x: 25, y: 75) < 10)
        #expect(alpha(erased, x: 75, y: 25) > 240)
        settings.isInverted = true
        let inverted = BackgroundRemovalImageRenderer.apply(settings, matte: nil, to: image)
        #expect(alpha(inverted, x: 25, y: 75) > 240)
        #expect(alpha(inverted, x: 75, y: 25) < 10)
        settings.isInverted = false
        settings.strokes.append(BackgroundBrushStroke(points: [point], diameter: 0.2, restores: true))
        let restored = BackgroundRemovalImageRenderer.apply(settings, matte: nil, to: image)
        #expect(alpha(restored, x: 25, y: 75) > 240)
    }

    private func alpha(_ image: CIImage, x: Int, y: Int) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.useSoftwareRenderer: true]).render(image, toBitmap: &pixel,
            rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
        return pixel[3]
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

private struct HalfForegroundSegmenter: ForegroundSegmenting {
    func mask(for pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws -> ForegroundMaskFrame {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        return ForegroundMaskFrame(width: width, height: height,
            values: (0..<(width * height)).map { $0 % width < width / 2 ? 1 : 0 })
    }
}
