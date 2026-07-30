import Foundation
import Testing

@testable import Motionary

@Suite(.serialized)
struct PreviewRebuildTests {
    @Test func renderInvalidationDetectsVisualOnlyChanges() async throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/visual.mov"),
            mediaType: .video,
            originalDuration: 4
        )
        let before = TimelineClip(
            name: "Clip",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4)
        )
        var after = before
        after.transform.opacity = AnimatableProperty(baseValue: 0.5)

        let invalidation = EditorProject.renderInvalidation(before: before, after: after)
        #expect(invalidation.contains(.previewFrame))
        #expect(!invalidation.contains(.compositionTopology))
        #expect(!invalidation.contains(.audioMix))
    }

    @Test func renderInvalidationDetectsAudioOnlyChanges() async throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/audio.mov"),
            mediaType: .video,
            originalDuration: 3
        )
        let before = TimelineClip(
            name: "Clip",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 3)
        )
        var after = before
        after.volume = AnimatableProperty(baseValue: 0.25)

        let invalidation = EditorProject.renderInvalidation(before: before, after: after)
        #expect(invalidation.contains(.audioMix))
        #expect(!invalidation.contains(.compositionTopology))
    }

    @Test func replaceClipCommandUsesCompactUndoPayload() async throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/compact.mov"),
            mediaType: .video,
            originalDuration: 2
        )
        let before = TimelineClip(
            name: "Clip",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        var after = before
        after.transform.opacity = AnimatableProperty(baseValue: 0.4)
        let command = EditorCommandFactory.replaceClip(
            before: before,
            after: after,
            invalidation: [.previewFrame]
        )
        var project = EditorProject(
            title: "Compact",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [before])]
        )
        project.registerMedia(from: source, mediaID: before.mediaID)

        command.apply(to: &project)
        #expect(project.tracks[0].clips[0].transform.opacity.baseValue == 0.4)

        command.undo(on: &project)
        #expect(project.tracks[0].clips[0].transform.opacity.baseValue == 1)
    }

    @Test func timelineClipEncodesWithoutEmbeddedSource() async throws {
        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/encode.mov"),
            mediaType: .video,
            originalDuration: 2
        )
        let clip = TimelineClip(
            name: "Clip",
            source: source,
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        var project = EditorProject(
            title: "Encode",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [clip])]
        )
        project.registerMedia(from: source, mediaID: clip.mediaID)
        let data = try JSONEncoder().encode(ProjectContent(editorProject: project))
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("\"source\""))
        #expect(json.contains("\"mediaID\""))
    }

    @MainActor
    @Test func interactivePreviewInvalidationsCoalesceWhileRendererIsBusy() async throws {
        let viewModel = makeViewModel()
        defer {
            viewModel.cancelInteractivePreviewRebuild()
            viewModel.isRenderingPreview = false
            viewModel.stop()
        }
        viewModel.isRenderingPreview = true

        viewModel.scheduleInteractivePreviewRebuild(invalidation: [.previewFrame])
        viewModel.scheduleInteractivePreviewRebuild(invalidation: [.audioMix])

        #expect(viewModel.previewQuality == .interactive)
        #expect(viewModel.pendingInteractivePreviewInvalidation.contains(.previewFrame))
        #expect(viewModel.pendingInteractivePreviewInvalidation.contains(.audioMix))
        #expect(viewModel.interactivePreviewThrottleTask != nil)
    }

    @MainActor
    @Test func interactiveEditCommitReturnsToBalancedQualityAndRecordsOneUndo() async throws {
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Interactive",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/interactive.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let viewModel = makeViewModel(clip: clip)
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }
        viewModel.selectClip(clipID, trackID: viewModel.project.tracks[0].id)
        viewModel.isRenderingPreview = true

        viewModel.setSelectedKeyframeValue(0.5, target: .positionX, interactive: true)
        #expect(viewModel.previewQuality == .interactive)
        #expect(viewModel.undoStack.isEmpty)
        #expect(viewModel.pendingInteractivePreviewInvalidation.contains(.previewFrame))

        viewModel.isRenderingPreview = false
        viewModel.finishInteractiveEdit()

        #expect(viewModel.previewQuality == .balanced)
        #expect(viewModel.pendingInteractivePreviewInvalidation.isEmpty)
        #expect(viewModel.undoStack.count == 1)
    }

    @MainActor
    @Test func previewTopologyRebuildsWhenCanvasGeometryChanges() async throws {
        let text = TextTimelineItem(
            text: "Canvas",
            timelineStart: 0,
            duration: 1
        )
        var project = EditorProject(
            title: "Canvas topology",
            renderSettings: RenderSettings(width: 320, height: 480, frameRate: 30),
            tracks: [
                TimelineTrack(
                    name: "Text",
                    kind: .text,
                    items: [.text(text)]
                )
            ]
        )
        let service = CompositionRenderService()

        let first = try await service.preparePreview(
            for: project,
            quality: .balanced,
            invalidation: [.previewFrame, .compositionTopology, .audioMix]
        )
        project.renderSettings = RenderSettings(width: 480, height: 320, frameRate: 30)
        let second = try await service.preparePreview(
            for: project,
            quality: .balanced,
            invalidation: [.previewFrame]
        )

        #expect(first?.topologyWasRebuilt == true)
        #expect(second?.topologyWasRebuilt == true)
    }

    @MainActor
    @Test func interactivePreviewKeepsGeneratedLayerRasterScaleAtPreviewResolution() async throws {
        let text = TextTimelineItem(
            text: "Interactive",
            timelineStart: 0,
            duration: 1
        )
        let project = EditorProject(
            title: "Interactive Raster Scale",
            renderSettings: RenderSettings(width: 1080, height: 1920, frameRate: 30),
            tracks: [
                TimelineTrack(
                    name: "Text",
                    kind: .text,
                    items: [.text(text)]
                )
            ]
        )
        let service = CompositionRenderService()

        let prepared = try await service.preparePreview(
            for: project,
            quality: .interactive,
            invalidation: [.previewFrame, .compositionTopology]
        )
        let instruction = try #require(
            prepared?.videoComposition?.instructions.first
                as? MotionaryVideoCompositionInstruction
        )

        #expect(instruction.renderSize == project.renderSettings.size)
        #expect(instruction.renderScale == 1)
        #expect(instruction.vectorRenderScale == 1)
    }

    @MainActor
    @Test func interactivePreviewKeepsEffectGeometryAtProjectResolution() async throws {
        let text = TextTimelineItem(
            text: "Dense scrub",
            timelineStart: 0,
            duration: 1
        )
        let project = EditorProject(
            title: "Interactive Preview Resolution",
            renderSettings: RenderSettings(width: 1080, height: 1920, frameRate: 30),
            tracks: [
                TimelineTrack(
                    name: "Text",
                    kind: .text,
                    items: [.text(text)]
                )
            ]
        )
        let service = CompositionRenderService()

        let prepared = try await service.preparePreview(
            for: project,
            quality: .interactive,
            invalidation: [.previewFrame, .compositionTopology]
        )
        let instruction = try #require(
            prepared?.videoComposition?.instructions.first
                as? MotionaryVideoCompositionInstruction
        )

        #expect(instruction.renderSize == project.renderSettings.size)
        #expect(instruction.renderScale == 1)
        #expect(instruction.vectorRenderScale == 1)
        #expect(instruction.qualityProfile == .interactive)
    }

    @MainActor
    private func makeViewModel(clip: TimelineClip? = nil) -> EditorViewModel {
        let tracks: [TimelineTrack]
        if let clip {
            tracks = [
                TimelineTrack(
                    name: clip.mediaType == .audio ? "Audio 1" : "Layer 1",
                    kind: clip.requiredTrackKind,
                    clips: [clip]
                )
            ]
        } else {
            tracks = []
        }
        return EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(
                editorProject: EditorProject(
                    title: "Preview Rebuilds",
                    tracks: tracks
                )
            )
        )
    }
}
