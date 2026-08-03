// Layer creation, persistence, deletion, and ordering tests.

import Foundation
import Testing

@testable import Motionary

@MainActor
struct LayerManagementTests {
    @Test func toolbarCanCreateMultipleTemporaryUndefinedLayers() async throws {
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: EditorProject.empty(title: "Toolbar Layer"))
        )

        viewModel.addLayer()
        viewModel.addLayer()

        let undefinedTracks = viewModel.project.tracks.filter { $0.kind == .undefined }
        #expect(undefinedTracks.count == 2)
        #expect(undefinedTracks.allSatisfy { $0.clips.isEmpty })
    }

    @Test func emptyUndefinedLayersAreRemovedDuringPersistenceRoundTrip() async throws {
        let project = EditorProject(
            title: "Temporary layers",
            tracks: [
                TimelineTrack(name: "Temporary 1", kind: .undefined),
                TimelineTrack(name: "Layer 1", kind: .visual),
                TimelineTrack(name: "Temporary 2", kind: .undefined)
            ]
        )

        let data = try JSONEncoder().encode(ProjectContent(editorProject: project))
        let decoded = try JSONDecoder().decode(ProjectContent.self, from: data)

        #expect(decoded.editorProject.tracks.count == 1)
        #expect(decoded.editorProject.tracks[0].kind == .visual)
    }

    @Test func emptyTypedLayersSurvivePersistenceRoundTrip() async throws {
        let project = EditorProject(
            title: "Typed layers",
            tracks: [
                TimelineTrack(name: "Layer 1", kind: .visual),
                TimelineTrack(name: "Audio 1", kind: .audio)
            ]
        )

        let data = try JSONEncoder().encode(ProjectContent(editorProject: project))
        let decoded = try JSONDecoder().decode(ProjectContent.self, from: data)

        #expect(decoded.editorProject.tracks.map(\.kind) == [.visual, .audio])
    }

    @MainActor
    @Test func deletingLayerRemovesItsClipsAndUpdatesSelection() async throws {
        let deletedTrackID = UUID()
        let remainingTrackID = UUID()
        let clipID = UUID()
        let clip = TimelineClip(
            id: clipID,
            name: "Deleted clip",
            source: ClipSource(url: URL(fileURLWithPath: "/tmp/deleted.mov"), mediaType: .video, originalDuration: 2),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Delete layer",
            tracks: [
                TimelineTrack(id: deletedTrackID, name: "Layer 1", kind: .visual, clips: [clip]),
                TimelineTrack(id: remainingTrackID, name: "Layer 2", kind: .visual)
            ]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.selectClip(clipID, trackID: deletedTrackID)

        viewModel.deleteLayer(deletedTrackID)

        #expect(viewModel.project.tracks.map(\.id) == [remainingTrackID])
        #expect(viewModel.selectedClipID == nil)
        #expect(viewModel.selectedTrackID == remainingTrackID)
    }

    @MainActor
    @Test func deletingLastClipKeepsItsLayer() async throws {
        let trackID = UUID()
        let clipID = UUID()
        let sourceURL = URL(fileURLWithPath: "/tmp/only.mov")
        let clip = TimelineClip(
            id: clipID,
            name: "Only clip",
            source: ClipSource(
                url: sourceURL,
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Keep layer",
            tracks: [
                TimelineTrack(id: trackID, name: "Layer 1", kind: .visual, clips: [clip])
            ]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.selectClip(clipID, trackID: trackID)

        viewModel.seek(to: viewModel.duration)

        #expect(abs(viewModel.currentTime - viewModel.duration) < 0.000_001)

        viewModel.deleteSelectedClip()

        #expect(viewModel.project.tracks.count == 1)
        #expect(viewModel.project.tracks[0].id == trackID)
        #expect(viewModel.project.tracks[0].clips.isEmpty)
        #expect(viewModel.project.tracks[0].kind == .undefined)
        #expect(viewModel.project.tracks[0].name == "Layer")
        #expect(viewModel.selectedClipID == nil)
        #expect(viewModel.selectedTrackID == trackID)
        #expect(viewModel.currentTime == 0)

        let persistedData = try JSONEncoder().encode(ProjectContent(editorProject: viewModel.project))
        let persistedContent = try JSONDecoder().decode(ProjectContent.self, from: persistedData)
        #expect(persistedContent.editorProject.tracks.count == 1)
        #expect(persistedContent.editorProject.tracks[0].id == trackID)
        #expect(persistedContent.editorProject.tracks[0].kind == .undefined)

        let textID = viewModel.addText()

        #expect(textID != nil)
        #expect(viewModel.project.tracks.count == 1)
        #expect(viewModel.project.tracks[0].id == trackID)
        #expect(viewModel.project.tracks[0].kind == .text)

        viewModel.undo()
        viewModel.undo()

        #expect(viewModel.project.tracks.count == 1)
        #expect(viewModel.project.tracks[0].id == trackID)
        #expect(viewModel.project.tracks[0].kind == .visual)
        #expect(viewModel.project.tracks[0].clips.map(\.id) == [clipID])
        #expect(viewModel.project.mediaAsset(for: viewModel.project.tracks[0].clips[0])?.url == sourceURL)
    }

    @MainActor
    @Test func newOverlayLayersStartOnCurrentVisibleFrame() async throws {
        let existingClip = TimelineClip(
            name: "Existing",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/existing.mov"),
                mediaType: .video,
                originalDuration: 4
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 4)
        )
        var project = EditorProject(
            title: "Visible frame insertion",
            tracks: [TimelineTrack(name: "Layer 1", kind: .visual, clips: [existingClip])]
        )
        project.renderSettings.frameRate = 30
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.currentTime = 1.049

        viewModel.addShape(.rectangle)
        let shape = try #require(viewModel.selectedTimelineItem?.legacyClip())
        #expect(abs(shape.timelineStart - (31.0 / 30.0)) < 0.000_001)
        #expect(abs(viewModel.currentTime - (31.0 / 30.0)) < 0.000_001)

        let source = ClipSource(
            url: URL(fileURLWithPath: "/tmp/imported.mov"),
            mediaType: .video,
            originalDuration: 2
        )
        viewModel.currentTime = 2.049
        viewModel.addImportedMedia(
            ImportedMedia(source: source, storedURL: source.url)
        )
        let imported = try #require(viewModel.selectedClip)
        #expect(abs(imported.timelineStart - (61.0 / 30.0)) < 0.000_001)
        #expect(abs(viewModel.currentTime - (61.0 / 30.0)) < 0.000_001)
    }

    @MainActor
    @Test func newTextLayersUseVisibleFrameAndLargerDefaultSize() async throws {
        var project = EditorProject(title: "Text defaults")
        project.renderSettings.frameRate = 30
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        viewModel.currentTime = 1.049

        let textID = try #require(viewModel.addText())
        guard case .text(let text) = try #require(viewModel.project.item(id: textID)) else {
            Issue.record("Expected inserted text item")
            return
        }

        #expect(abs(text.timelineStart - (31.0 / 30.0)) < 0.000_001)
        #expect(abs(viewModel.currentTime - (31.0 / 30.0)) < 0.000_001)
        #expect(text.style.fontSize == 72)
        #expect(text.propertyAnimations.fontSize.baseValue == 72)
    }

    @MainActor
    @Test func deletingOnlyClipRemovesLayerWhenAnotherLayerRemains() async throws {
        let deletedTrackID = UUID()
        let remainingTrackID = UUID()
        let clip = TimelineClip(
            name: "Only layer clip",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/only-layer-clip.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(
                editorProject: EditorProject(
                    title: "Remove empty layer",
                    tracks: [
                        TimelineTrack(id: deletedTrackID, name: "Layer 1", kind: .visual, clips: [clip]),
                        TimelineTrack(id: remainingTrackID, name: "Layer", kind: .undefined),
                    ]
                )
            )
        )
        viewModel.selectClip(clip.id, trackID: deletedTrackID)

        viewModel.deleteSelectedClip()

        #expect(viewModel.project.tracks.map(\.id) == [remainingTrackID])
        #expect(viewModel.selectedTrackID == remainingTrackID)

        viewModel.undo()

        #expect(viewModel.project.tracks.map(\.id) == [deletedTrackID, remainingTrackID])
        #expect(viewModel.project.clip(id: clip.id) != nil)
    }

    @MainActor
    @Test func trackReorderUsesVisibleAbsoluteIndicesAcrossKinds() async throws {
        let visualID = UUID()
        let audioID = UUID()
        let undefinedID = UUID()
        let project = EditorProject(
            title: "Track order",
            tracks: [
                TimelineTrack(id: visualID, name: "Layer 1", kind: .visual),
                TimelineTrack(id: audioID, name: "Audio 1", kind: .audio),
                TimelineTrack(id: undefinedID, name: "Layer", kind: .undefined)
            ]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: project)
        )
        let previewGenerationBeforeReorder = viewModel.previewGeneration

        viewModel.moveTrack(audioID, to: 0)
        #expect(viewModel.project.tracks.map(\.id) == [audioID, visualID, undefinedID])
        #expect(viewModel.previewGeneration > previewGenerationBeforeReorder)

        viewModel.moveTrack(undefinedID, to: 1)
        #expect(viewModel.project.tracks.map(\.id) == [audioID, undefinedID, visualID])
    }

    @Test func automergeUsesTopMatchingLayerWhenImportedRangeIsFree() {
        let occupied = TimelineClip(
            name: "Existing",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/existing.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Automerge",
            tracks: [
                TimelineTrack(name: "Layer 1", kind: .visual, clips: [occupied]),
                TimelineTrack(name: "Layer 2", kind: .visual)
            ]
        )

        #expect(project.topAvailableTrackIndex(kind: .visual, start: 2, duration: 3) == 0)
        #expect(project.topAvailableTrackIndex(kind: .visual, start: 1, duration: 3) == 1)
        #expect(project.topAvailableTrackIndex(kind: .audio, start: 0, duration: 3) == nil)
    }

    @MainActor
    @Test func adjustmentAndContentCreationUseSeparateVisualTracks() async throws {
        let content = TimelineClip(
            name: "Content",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/content.mov"),
                mediaType: .video,
                originalDuration: 1
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(
                editorProject: EditorProject(
                    title: "Dedicated adjustment track",
                    tracks: [
                        TimelineTrack(name: "Layer 1", kind: .visual, clips: [content])
                    ]
                )
            )
        )
        viewModel.seek(to: viewModel.duration)

        let adjustmentID = try #require(viewModel.addAdjustmentLayer())
        let adjustmentLocation = try #require(
            viewModel.project.itemLocation(id: adjustmentID)
        )
        let contentLocation = try #require(
            viewModel.project.itemLocation(id: content.id)
        )

        #expect(adjustmentLocation.track != contentLocation.track)
        let adjustmentTrackContainsOnlyAdjustments =
            viewModel.project.tracks[adjustmentLocation.track].items
            .allSatisfy(\.isAdjustmentLayer)
        let contentTrackContainsAdjustment =
            viewModel.project.tracks[contentLocation.track].items
            .contains(where: \.isAdjustmentLayer)
        #expect(adjustmentTrackContainsOnlyAdjustments)
        #expect(!contentTrackContainsAdjustment)

        let importedSource = ClipSource(
            url: URL(fileURLWithPath: "/tmp/import-after-adjustment.mov"),
            mediaType: .video,
            originalDuration: 1
        )
        viewModel.currentTime = 2
        viewModel.addImportedMedia(
            ImportedMedia(source: importedSource, storedURL: importedSource.url)
        )
        let importedID = try #require(viewModel.selectedClipID)
        let importedLocation = try #require(
            viewModel.project.itemLocation(id: importedID)
        )

        #expect(importedLocation.track != adjustmentLocation.track)
        let importedTrackContainsAdjustment =
            viewModel.project.tracks[importedLocation.track].items
            .contains(where: \.isAdjustmentLayer)
        #expect(!importedTrackContainsAdjustment)
    }

    @Test func placementCannotCrossAdjustmentAndContentTrackRoles() throws {
        let adjustment = AdjustmentTimelineItem(
            timelineStart: 0,
            duration: 2
        )
        let content = TimelineClip(
            name: "Content",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/placement-content.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Placement roles",
            tracks: [
                TimelineTrack(
                    name: "Adjustment",
                    kind: .visual,
                    items: [.adjustment(adjustment)]
                ),
                TimelineTrack(name: "Content", kind: .visual, clips: [content]),
            ]
        )

        var adjustmentProposal = project
        let proposedAdjustmentPlacement = adjustmentProposal.resolveClipPlacement(
            adjustment.id,
            proposedStart: 3,
            proposedTrackIndex: 1,
            currentTime: 3
        )
        let adjustmentPlacement = try #require(proposedAdjustmentPlacement)
        #expect(adjustmentPlacement.trackIndex == 0)
        var adjustmentResult = project
        _ = adjustmentResult.placeClip(adjustment.id, using: adjustmentPlacement)
        #expect(adjustmentResult.itemLocation(id: adjustment.id)?.track == 0)
        let adjustmentResultIsHomogeneous =
            adjustmentResult.tracks[0].items.allSatisfy(\.isAdjustmentLayer)
        #expect(adjustmentResultIsHomogeneous)

        var contentProposal = project
        let proposedContentPlacement = contentProposal.resolveClipPlacement(
            content.id,
            proposedStart: 3,
            proposedTrackIndex: 0,
            currentTime: 3
        )
        let contentPlacement = try #require(proposedContentPlacement)
        #expect(contentPlacement.trackIndex == 1)
        var contentResult = project
        _ = contentResult.placeClip(content.id, using: contentPlacement)
        #expect(contentResult.itemLocation(id: content.id)?.track == 1)
        let contentResultContainsAdjustment =
            contentResult.tracks[1].items.contains(where: \.isAdjustmentLayer)
        #expect(!contentResultContainsAdjustment)
    }

    @Test func mixedLegacyAdjustmentTrackIsNormalizedOnLoad() throws {
        let adjustment = AdjustmentTimelineItem(
            timelineStart: 0,
            duration: 2
        )
        let content = TimelineClip(
            name: "Legacy content",
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/legacy-mixed.mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let project = EditorProject(
            title: "Normalize mixed adjustment",
            tracks: [
                TimelineTrack(
                    name: "Legacy mixed",
                    kind: .visual,
                    items: [
                        .adjustment(adjustment),
                        .fromLegacyClip(content),
                    ]
                )
            ]
        )

        #expect(project.tracks.count == 2)
        #expect(project.tracks[0].items.map(\.id) == [adjustment.id])
        let firstProjectTrackIsAdjustmentOnly =
            project.tracks[0].items.allSatisfy(\.isAdjustmentLayer)
        #expect(firstProjectTrackIsAdjustmentOnly)
        #expect(project.tracks[0].name == "Adjustment 1")
        #expect(project.tracks[1].items.map(\.id) == [content.id])
        let secondProjectTrackContainsAdjustment =
            project.tracks[1].items.contains(where: \.isAdjustmentLayer)
        #expect(!secondProjectTrackContainsAdjustment)
        #expect(project.tracks[1].name == "Layer 1")

        let decoded = try JSONDecoder().decode(
            EditorProject.self,
            from: JSONEncoder().encode(project)
        )
        #expect(decoded.tracks.count == 2)
        let firstDecodedTrackIsAdjustmentOnly =
            decoded.tracks[0].items.allSatisfy(\.isAdjustmentLayer)
        let secondDecodedTrackContainsAdjustment =
            decoded.tracks[1].items.contains(where: \.isAdjustmentLayer)
        #expect(firstDecodedTrackIsAdjustmentOnly)
        #expect(!secondDecodedTrackContainsAdjustment)
    }

    @Test func adjustmentSplitAndTrimPreserveLocalKeyframeContinuity() throws {
        let position = AnimatableProperty(
            baseValue: 0.0,
            keyframes: [
                Keyframe(time: 0, value: 0),
                Keyframe(time: 2, value: 20),
                Keyframe(time: 4, value: 40),
            ]
        )
        let item = TimelineItem.adjustment(
            AdjustmentTimelineItem(
                timelineStart: 1,
                duration: 4,
                visuals: TimelineItemVisuals(
                    transform: ClipTransform(positionX: position)
                )
            )
        )

        let split = try #require(item.split(at: 2))
        guard case .adjustment(let left) = split.left,
            case .adjustment(let right) = split.right
        else {
            Issue.record("Splitting changed the adjustment layer kind")
            return
        }
        #expect(left.duration == 2)
        #expect(right.timelineStart == 3)
        #expect(right.duration == 2)
        #expect(left.visuals.transform.positionX.value(at: 2) == 20)
        #expect(right.visuals.transform.positionX.value(at: 0) == 20)
        #expect(right.visuals.transform.positionX.value(at: 2) == 40)

        guard case .adjustment(let trimmedStart) = item.trimmingStart(by: 1),
            case .adjustment(let trimmedEnd) = item.trimmingEnd(by: -1)
        else {
            Issue.record("Trimming changed the adjustment layer kind")
            return
        }
        #expect(trimmedStart.timelineStart == 2)
        #expect(trimmedStart.duration == 3)
        #expect(trimmedStart.visuals.transform.positionX.value(at: 0) == 10)
        #expect(trimmedStart.visuals.transform.positionX.value(at: 3) == 40)
        #expect(trimmedEnd.duration == 3)
        #expect(trimmedEnd.visuals.transform.positionX.value(at: 3) == 30)
    }

    @MainActor
    @Test func adjustmentEffectsUseGenericInspectorWithoutLosingTypedIdentity() throws {
        let adjustment = AdjustmentTimelineItem(
            timelineStart: 0,
            duration: 3,
            visuals: TimelineItemVisuals(
                blendMode: .multiply,
                blendIntensity: 0.75,
                mask: ItemMask(shape: .ellipse)
            )
        )
        let track = TimelineTrack(
            name: "Adjustment",
            kind: .visual,
            items: [.adjustment(adjustment)]
        )
        let viewModel = EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(
                editorProject: EditorProject(
                    title: "Adjustment effects",
                    tracks: [track]
                )
            )
        )
        viewModel.selectTimelineItem(adjustment.id, trackID: track.id)
        viewModel.currentTime = 1

        let effectID = try #require(viewModel.addEffect(moduleID: .noir))
        viewModel.toggleEffectKeyframe(effectID)
        viewModel.setSelectedKeyframeValue(
            0.35,
            target: .effectMix(effectID)
        )

        guard case .adjustment(let edited) = try #require(
            viewModel.project.item(id: adjustment.id)
        ) else {
            Issue.record("The generic effects inspector converted the adjustment into content")
            return
        }
        let effect = try #require(
            edited.visuals.effectStack.effects.first { $0.id == effectID }
        )
        let keyframe = try #require(
            effect.mix.keyframes.first {
                abs($0.time - 1) <= viewModel.keyframeTimeTolerance
            }
        )
        #expect(keyframe.value == 0.35)
        #expect(edited.visuals.blendMode == .multiply)
        #expect(edited.visuals.blendIntensity == 0.75)
        #expect(edited.visuals.mask?.shape == .ellipse)
        let trackRemainsAdjustmentOnly =
            viewModel.project.tracks[0].items.allSatisfy(\.isAdjustmentLayer)
        #expect(trackRemainsAdjustmentOnly)
    }
}
