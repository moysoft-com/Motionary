// Exercises production effects gestures without touching stored user projects.
#if DEBUG
import SwiftUI

struct EffectsGestureTestScene: View {
    @StateObject private var viewModel: EditorViewModel
    @State private var activeEffectID: UUID?
    @State private var peakProgress: CGFloat = 0
    private let side = ProcessInfo.processInfo.arguments.contains("--effects-side")

    init() {
        var shape = ShapeTimelineItem(
            name: "Gesture shape", mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle, color: .white, width: 96, height: 96),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        shape.visuals.effectStack = EffectStack(effects: [EffectRegistry.shared.makeEffect(moduleID: .noir)!])
        let track = TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])
        let model = EditorViewModel(projectID: UUID(), projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: EditorProject(title: "Effects gesture tests", tracks: [track])))
        model.selectTimelineItem(shape.id, trackID: track.id)
        _viewModel = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(String(format: "%.3f", peakProgress)).accessibilityIdentifier("effects-test-peak")
            Button("Reset peak") { peakProgress = 0 }
            EffectsWorkspaceView(
                viewModel: viewModel, clip: viewModel.project.tracks.first?.items.first?.visualEditingClip(),
                activeEffectID: $activeEffectID,
                onPullProgressChanged: { peakProgress = max(peakProgress, $0) }
            )
            .environment(\.editorUsesSideWorkspace, side)
            .frame(height: 360)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("effects-test-workspace")
        }
        .padding(16)
    }
}
#endif
