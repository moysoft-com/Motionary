import Foundation
import Testing

@testable import Motionary

@Suite(.serialized)
struct SelectionLookupIndexTests {
    @MainActor
    @Test func playbackSelectionReadsReuseOneItemIndex() {
        let clips = (0..<240).map { index in
            makeClip(
                name: "Clip \(index)",
                timelineStart: Double(index) * 0.25
            )
        }
        let selected = clips[173]
        let track = TimelineTrack(
            name: "Dense Layer",
            kind: .visual,
            clips: clips
        )
        let viewModel = makeViewModel(tracks: [track])
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }
        viewModel.selectClip(selected.id, trackID: track.id)
        let initialRebuildCount = viewModel.projectItemLookupIndex.rebuildCount
        #expect(initialRebuildCount == 1)

        for tick in 0..<1_000 {
            viewModel.updateCurrentTime(Double(tick % 120) / 60)
            #expect(viewModel.selectedTimelineItem?.id == selected.id)
            #expect(viewModel.selectedClip?.id == selected.id)
            #expect(viewModel.selectedKeyframeEditingClip?.id == selected.id)
            if let clip = viewModel.selectedClip {
                _ = viewModel.isTimeInside(clip)
                _ = viewModel.timelinePlacementDuration(for: clip)
            }
        }
        #expect(viewModel.projectItemLookupIndex.rebuildCount == initialRebuildCount)

        viewModel.setSelectedKeyframeValue(
            0.42,
            target: .opacity
        )
        #expect(
            viewModel.selectedClip?.transform.opacity.baseValue == 0.42
        )
        #expect(viewModel.projectItemLookupIndex.rebuildCount == initialRebuildCount)
    }

    @MainActor
    @Test func structuralMutationAndUndoRefreshCachedLocation() throws {
        let selected = makeClip(name: "Selected", timelineStart: 1)
        let track = TimelineTrack(
            name: "Layer",
            kind: .visual,
            clips: [selected]
        )
        let viewModel = makeViewModel(tracks: [track])
        defer {
            viewModel.rebuildTask?.cancel()
            viewModel.stop()
        }
        viewModel.selectClip(selected.id, trackID: track.id)
        let initialRebuildCount = viewModel.projectItemLookupIndex.rebuildCount
        #expect(
            viewModel.indexedTimelineItemLocation(id: selected.id)
                == ProjectItemIndexLocation(track: 0, item: 0)
        )

        let inserted = makeClip(name: "Inserted", timelineStart: 0)
        viewModel.mutateProject(rebuild: false) { project in
            project.tracks[0].items.insert(
                TimelineItem.fromLegacyClip(inserted),
                at: 0
            )
        }

        #expect(viewModel.selectedTimelineItem?.id == selected.id)
        #expect(
            viewModel.indexedTimelineItemLocation(id: selected.id)
                == ProjectItemIndexLocation(track: 0, item: 1)
        )
        #expect(viewModel.projectItemLookupIndex.rebuildCount == initialRebuildCount + 1)

        viewModel.undo()

        #expect(viewModel.selectedTimelineItem?.id == selected.id)
        #expect(
            viewModel.indexedTimelineItemLocation(id: selected.id)
                == ProjectItemIndexLocation(track: 0, item: 0)
        )
        #expect(viewModel.projectItemLookupIndex.rebuildCount == initialRebuildCount + 2)
    }

    private func makeClip(name: String, timelineStart: Double) -> TimelineClip {
        TimelineClip(
            name: name,
            source: ClipSource(
                url: URL(fileURLWithPath: "/tmp/\(name).mov"),
                mediaType: .video,
                originalDuration: 2
            ),
            timelineStart: timelineStart,
            sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
    }

    @MainActor
    private func makeViewModel(tracks: [TimelineTrack]) -> EditorViewModel {
        EditorViewModel(
            projectID: UUID(),
            projectStore: ProjectStore(),
            initialContent: ProjectContent(
                editorProject: EditorProject(
                    title: "Selection index",
                    tracks: tracks
                )
            )
        )
    }
}
