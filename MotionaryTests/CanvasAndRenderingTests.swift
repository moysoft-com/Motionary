// Canvas sizing and empty-composition rendering tests.

import AVFoundation
import Foundation
import Testing
import UIKit

@testable import Motionary

@Suite(.serialized)
struct CanvasAndRenderingTests {
    @MainActor
    @Test func configurableExporterWritesRequestedDimensions() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 96)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 96))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 32, y: 0, width: 32, height: 96))
        }
        let sourceURL = try await MediaConversionHelper.imageToVideo(
            image: image,
            duration: 0.2,
            frameRate: 10
        )
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let source = try await MediaImportService().makeSource(
            for: sourceURL,
            fallbackMediaType: .video
        )
        let clip = TimelineClip(
            name: "Export",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 0.2)
        )
        let project = EditorProject(
            title: "Export",
            renderSettings: RenderSettings(width: 64, height: 96, frameRate: 10),
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        let settings = VideoExportSettings(
            width: 80,
            height: 120,
            frameRate: 10,
            videoBitrate: 500_000,
            audioBitrate: 96_000,
            codec: .h264,
            container: .mp4
        )

        let outputURL = try await VideoExportService().export(
            project: project,
            settings: settings,
            progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let outputAsset = AVURLAsset(url: outputURL)
        let outputTrack = try #require(
            try await outputAsset.loadTracks(withMediaType: .video).first
        )
        let outputSize = try await outputTrack.load(.naturalSize)

        #expect(Int(outputSize.width.rounded()) == 80)
        #expect(Int(outputSize.height.rounded()) == 120)
        #expect(CMTimeGetSeconds(try await outputAsset.load(.duration)) > 0)
    }

    @Test func videoTrackMatricesNormalizeFullDisplayGeometry() async throws {
        let naturalSize = CGSize(width: 1920, height: 1080)
        let transforms = [
            CGAffineTransform.identity,
            CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0),
            CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080),
            CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920),
            CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1920, ty: 0),
            CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1080),
            CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0),
            CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 1080, ty: 1920)
        ]

        for transform in transforms {
            let displayRect = VideoSourceGeometry.displayRect(
                naturalSize: naturalSize,
                transform: transform
            )
            let normalized = CGRect(origin: .zero, size: naturalSize)
                .applying(
                    VideoSourceGeometry.normalizedTransform(
                        naturalSize: naturalSize,
                        transform: transform
                    )
                )
                .standardized

            #expect(abs(normalized.minX) < 0.001)
            #expect(abs(normalized.minY) < 0.001)
            #expect(abs(normalized.width - displayRect.width) < 0.001)
            #expect(abs(normalized.height - displayRect.height) < 0.001)
        }
    }

    @Test func stillVideoContainsAtMostTwoFrames() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
            UIColor.green.setFill()
            context.fill(CGRect(x: 24, y: 0, width: 24, height: 16))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 16, width: 24, height: 16))
            UIColor.yellow.setFill()
            context.fill(CGRect(x: 24, y: 16, width: 24, height: 16))
        }
        let url = try await MediaConversionHelper.imageToVideo(
            image: image,
            duration: 5,
            frameRate: 30
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        _ = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(MediaConversionHelper.stillVideoSourceFrameCount <= 2)
        #expect(abs(CMTimeGetSeconds(try await asset.load(.duration)) - 5) < 0.05)
    }

    @Test func exportSettingsNormalizeEncoderDimensionsAndRates() async throws {
        let settings = VideoExportSettings(
            width: 1_081,
            height: 1_921,
            frameRate: 0,
            videoBitrate: 100,
            audioBitrate: 1_000_000,
            codec: .h264,
            container: .mp4
        ).normalized

        #expect(settings.width == 1_080)
        #expect(settings.height == 1_920)
        #expect(settings.frameRate == 1)
        #expect(settings.videoBitrate == 500_000)
        #expect(settings.audioBitrate == 320_000)
    }

    @MainActor
    @Test func originalRatioUsesSelectedVisualClipSizeAndPreservesFrameRate() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Landscape",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/landscape.mov"),
                mediaType: .video,
                originalDuration: 2,
                naturalSize: CGSizeValue(width: 1280, height: 720)
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Original Ratio",
            renderSettings: RenderSettings(width: 1080, height: 1920, frameRate: 60),
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )

        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)
        viewModel.setCanvasToSelectedClipOriginalRatio()

        #expect(viewModel.project.renderSettings.width == 1280)
        #expect(viewModel.project.renderSettings.height == 720)
        #expect(viewModel.project.renderSettings.frameRate == 60)
    }

    @Test func emptyProjectCompositionIsValidAndVideoFree() async throws {
        let project = EditorProject.empty(title: "Empty")
        let rendered = try await CompositionRenderService().makeComposition(for: project)

        #expect(rendered.duration == 0)
        #expect(rendered.hasVideo == false)
        #expect(rendered.videoComposition == nil)
    }

    @Test func textRendererKeepsMultilineGeometryStableDuringTypewriterReveal() async throws {
        let style = TextStyle(
            fontName: "Missing-Font-Falls-Back",
            fontSize: 42,
            color: .white,
            alignment: .trailing,
            letterSpacing: 2,
            lineSpacing: 7,
            stroke: TextStrokeStyle(width: 3),
            shadow: TextShadowStyle(offsetX: 4, offsetY: 5, blur: 8),
            background: TextBackgroundStyle(padding: 14, cornerRadius: 10)
        )
        let multiline = TextTimelineItem(
            text: "First line\nSecond line",
            style: style,
            layout: TextLayout(widthFraction: 0.7),
            timelineStart: 0,
            duration: 2
        )
        let singleLine = TextTimelineItem(
            text: "First line",
            style: style,
            layout: TextLayout(widthFraction: 0.7),
            timelineStart: 0,
            duration: 2
        )
        let renderer = TextLayerRenderer()
        let hidden = renderer.render(
            item: multiline,
            renderSize: CGSize(width: 600, height: 800),
            renderScale: 1,
            glyphReveal: 0
        )
        let visible = renderer.render(
            item: multiline,
            renderSize: CGSize(width: 600, height: 800),
            renderScale: 1,
            glyphReveal: 1
        )
        let singleGeometry = TextLayerRenderer.geometry(
            for: singleLine,
            renderSize: CGSize(width: 600, height: 800),
            renderScale: 1
        )

        #expect(hidden.geometry == visible.geometry)
        #expect(visible.geometry.layerSize.height > singleGeometry.layerSize.height)
        #expect(abs(visible.geometry.backgroundRect!.width - 420) < 0.001)
        #expect(
            TextLayerRenderer.resolvedFont(for: style, renderScale: 1).fontName
                == UIFont.systemFont(ofSize: 42, weight: .semibold).fontName
        )
    }

    @Test func textOnlyCompositionGetsTemporaryVideoClock() async throws {
        let text = TextTimelineItem(
            text: "Text only",
            timelineStart: 0,
            duration: 0.2
        )
        let project = EditorProject(
            title: "Text only",
            renderSettings: RenderSettings(width: 96, height: 128, frameRate: 10),
            tracks: [
                TimelineTrack(
                    name: "Text 1",
                    kind: .text,
                    items: [.text(text)]
                )
            ]
        )

        let rendered = try await CompositionRenderService().makeComposition(for: project)

        #expect(rendered.hasVideo)
        #expect(rendered.videoComposition != nil)
        #expect(rendered.videoClockTrackID != nil)
        #expect(!rendered.composition.tracks(withMediaType: .video).isEmpty)
    }

    @Test func zeroVolumeVideoStillParticipatesInAudioTopology() async throws {
        let clip = TimelineClip(
            name: "Muted",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/muted.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2),
            volume: AnimatableProperty(baseValue: 0)
        )

        #expect(CompositionRenderService.shouldIncludeSourceAudio(for: clip))
    }
}
