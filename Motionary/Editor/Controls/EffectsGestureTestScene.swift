// Exercises production effects gestures without touching stored user projects.
#if DEBUG
import SwiftUI
import UIKit

struct EffectsGestureTestScene: View {
    @StateObject private var viewModel: EditorViewModel
    @State private var activeEffectID: UUID?
    @State private var peakProgress: CGFloat = 0
    private let side = ProcessInfo.processInfo.arguments.contains("--effects-side")
    private let livePreview = ProcessInfo.processInfo.arguments.contains("--scrubber-live-preview-test")

    init() {
        var shape = ShapeTimelineItem(
            name: "Gesture shape", mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle, color: .white, width: 96, height: 96),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 2)
        )
        let testsMomentum = ProcessInfo.processInfo.arguments.contains("--scrubber-momentum-test")
            || ProcessInfo.processInfo.arguments.contains("--scrubber-live-preview-test")
        let moduleID: EffectModuleID = testsMomentum ? .cameraWiggle : .noir
        shape.visuals.effectStack = EffectStack(effects: [EffectRegistry.shared.makeEffect(moduleID: moduleID)!])
        let track = TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])
        let model = EditorViewModel(projectID: UUID(), projectStore: ProjectStore(),
            initialContent: ProjectContent(editorProject: EditorProject(title: "Effects gesture tests", tracks: [track])))
        model.selectTimelineItem(shape.id, trackID: track.id)
        _viewModel = StateObject(wrappedValue: model)
        if ProcessInfo.processInfo.arguments.contains("--scrubber-live-preview-test") {
            _activeEffectID = State(initialValue: shape.visuals.effectStack.effects.first?.id)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            if livePreview, let player = viewModel.player {
                ZStack {
                    PreviewRendererView(player: player)
                    LivePreviewSurface(presentation: viewModel.livePreviewPresentation)
                }
                .frame(height: 160)
            }
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
        .background {
            if livePreview { WorkspaceFrameProbe().allowsHitTesting(false) }
        }
        .task {
            guard livePreview else { return }
            // Use a real decoded source and the production player/compositor.
            // The gesture-only fixture cannot expose commit-time AVPlayer work.
            guard let item = viewModel.project.tracks.first?.items.first,
                let effects = item.editableVisuals?.effectStack,
                let url = try? await MediaConversionHelper.blankVideoClockURL(duration: 2, frameRate: 30)
            else { return }
            var clip = TimelineClip(id: item.id, name: "Decoded momentum fixture",
                source: ClipSource(url: url, mediaType: .video, originalDuration: 2,
                    naturalSize: CGSizeValue(width: 64, height: 64)),
                timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 2))
            clip.effectStack = effects
            let track = TimelineTrack(name: "Video", kind: .visual, clips: [clip])
            viewModel.project = EditorProject(title: "Decoded scrubber",
                renderSettings: RenderSettings(width: 540, height: 960, frameRate: 30), tracks: [track])
            viewModel.selectTimelineItem(clip.id, trackID: track.id)
            viewModel.start()
        }
        .onDisappear { if livePreview { viewModel.stop() } }
    }
}

/// Simulator-only diagnostic: reports actual run-loop delivery gaps while HID
/// gestures are sent without XCTest's automatic wait-for-idle behavior.
private struct WorkspaceFrameProbe: UIViewRepresentable {
    final class Probe: UIView {
        private var link: CADisplayLink?
        private var previous: CFTimeInterval?
        private var gaps: [Double] = []
        private final class Target: NSObject {
            weak var probe: Probe?
            @objc func tick(_ link: CADisplayLink) { probe?.tick(link) }
        }
        private let target = Target()
        override func didMoveToWindow() {
            super.didMoveToWindow()
            link?.invalidate()
            link = nil
            guard window != nil else { return }
            target.probe = self
            let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        private func tick(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            defer { previous = now }
            guard let previous else { return }
            gaps.append((now - previous) * 1000)
            if gaps.count == 120 {
                let sorted = gaps.sorted()
                print("WORKSPACE_FRAME_METRIC p95_ms=\(sorted[114]) max_ms=\(sorted[119])")
                gaps.removeAll(keepingCapacity: true)
            }
        }
        deinit { link?.invalidate() }
    }
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {}
}
/// Full production editor fixture for inspecting adjustment effects and graph navigation.
struct AdjustmentEditorTestScene: View {
    @StateObject private var store = ProjectStore()
    private let projectID = UUID()
    private let content: ProjectContent

    init() {
        var effect = EffectRegistry.shared.makeEffect(moduleID: .noir)!
        effect.mix = AnimatableProperty(baseValue: 1, keyframes: [
            Keyframe(time: 0, value: 0.2), Keyframe(time: 1, value: 0.8), Keyframe(time: 3, value: 0.4)
        ])
        let adjustment = AdjustmentTimelineItem(timelineStart: 0, duration: 4,
            visuals: TimelineItemVisuals(effectStack: EffectStack(effects: [effect])))
        let shape = ShapeTimelineItem(name: "Rectangle", mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle, color: .white, width: 400, height: 400),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 4))
        content = ProjectContent(editorProject: EditorProject(title: "Adjustment inspection", tracks: [
            TimelineTrack(name: "Adjustment", kind: .visual, items: [.adjustment(adjustment)]),
            TimelineTrack(name: "Shape", kind: .shape, items: [.shape(shape)])
        ]))
    }

    var body: some View {
        ProjectEditorView(projectID: projectID, projectStore: store, initialContent: content)
    }
}
#endif
