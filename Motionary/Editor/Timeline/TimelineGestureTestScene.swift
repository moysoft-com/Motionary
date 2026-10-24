// Deterministic Debug-only fixture that exercises the production timeline gestures.
#if DEBUG
    import SwiftUI

    struct TimelineGestureTestScene: View {
        @StateObject private var viewModel: EditorViewModel
        @State private var pixelsPerSecond: CGFloat = 88

        init() {
            let tracks = (1...16).map { index in
                TimelineTrack(
                    id: Self.identifier(index + 100), name: "Layer \(index)", kind: .text,
                    items: [
                        .text(
                            TextTimelineItem(
                                id: Self.identifier(index), name: "Item \(index)", text: "Test",
                                timelineStart: 0.5, duration: 2
                            ))
                    ]
                )
            }
            _viewModel = StateObject(
                wrappedValue: EditorViewModel(
                    projectID: UUID(), projectStore: ProjectStore(),
                    initialContent: ProjectContent(editorProject: EditorProject(title: "Gesture tests", tracks: tracks))
                ))
        }

        private static func identifier(_ index: Int) -> UUID {
            UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index)))
        }

        var body: some View {
            VStack(spacing: 20) {
                TimelineGestureTestStatus(viewModel: viewModel)
                CoreTimelineView(viewModel: viewModel, pixelsPerSecond: $pixelsPerSecond)
                    .frame(height: 300)
                Button("Deselect") { viewModel.deselectTimeline() }
                Button("Set playing") { viewModel.isPlaying = true }
            }
            .padding(12)
        }
    }

    private struct TimelineGestureTestStatus: View {
        let viewModel: EditorViewModel
        @ObservedObject private var selection: SelectionState
        @ObservedObject private var timeline: TimelineState
        @ObservedObject private var playback: PlaybackState

        init(viewModel: EditorViewModel) {
            self.viewModel = viewModel
            _selection = ObservedObject(wrappedValue: viewModel.selectionState)
            _timeline = ObservedObject(wrappedValue: viewModel.timelineState)
            _playback = ObservedObject(wrappedValue: viewModel.playbackState)
        }

        var body: some View {
            let items = viewModel.project.tracks.flatMap(\.items)
            let first = items.first { $0.id.uuidString.hasSuffix("000000000001") }
            VStack {
                Text(selection.clipID?.uuidString ?? "none").accessibilityIdentifier("test-selection")
                Text(String(format: "%.3f", first?.timelineStart ?? -1)).accessibilityIdentifier("test-start")
                Text(String(format: "%.3f", first?.placementDuration ?? -1)).accessibilityIdentifier("test-duration")
                Text(
                    String(
                        viewModel.project.tracks.firstIndex { track in
                            track.items.contains { $0.id.uuidString.hasSuffix("000000000001") }
                        } ?? -1)
                ).accessibilityIdentifier("test-first-track-index")
                Text(playback.isPlaying ? "playing" : "paused").accessibilityIdentifier("test-playback")
                Text(String(format: "%.3f", playback.currentTime)).accessibilityIdentifier("test-time")
            }
            .font(.caption2)
        }
    }
#endif
