// Speed and mask workspaces for typed timeline items.

import SwiftUI

struct SpeedWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let item: TimelineItem?
    @State private var speedEditSession: SpeedEditSession?

    var body: some View {
        Group {
            if let item, case .media(let media) = item,
                media.mediaType == .video || media.mediaType == .audio
            {
                PropertyWorkspaceShell(
                    viewModel: viewModel,
                    clip: item.legacyClip(),
                    title: "Speed",
                    systemImage: "speedometer",
                    section: nil
                ) { _, isEnabled in
                    VStack(spacing: 14) {
                        speedScrubber(
                            value: viewModel.selectedSpeedAtPlayhead
                                ?? media.speedMap.speed(at: 0),
                            isEnabled: isEnabled
                        )

                        Toggle(
                            "Pitch follows speed",
                            isOn: Binding(
                                get: { media.pitchFollowsSpeed },
                                set: { viewModel.setSelectedPitchFollowsSpeed($0) }
                            )
                        )
                        .font(.callout.weight(.medium))
                        .tint(MotionaryTheme.accent)
                        .disabled(!isEnabled)

                        Toggle("Ripple following clips", isOn: $viewModel.isRippleEditingEnabled)
                            .font(.callout.weight(.medium))
                            .tint(MotionaryTheme.accent)
                            .disabled(!isEnabled)

                        Text(
                            viewModel.isRippleEditingEnabled
                                ? "Following clips move with duration changes."
                                : "Slower speeds stop before they overlap the next clip."
                        )
                        .font(.caption)
                        .foregroundStyle(MotionaryTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                TimelineItemWorkspaceShell(
                    viewModel: viewModel,
                    item: item,
                    title: "Speed",
                    systemImage: "speedometer"
                ) { _, _ in
                    EditorWorkspaceMessage(
                        text: "Speed controls are available for video and audio clips.",
                        systemImage: "speedometer"
                    )
                }
            }
        }
        .onDisappear {
            finishSpeedEditIfNeeded()
        }
        .onChange(of: item?.id) { _, _ in
            finishSpeedEditIfNeeded()
        }
    }

    private func speedScrubber(
        value: Double,
        isEnabled: Bool
    ) -> some View {
        EditorValueScrubber(
            title: "Speed",
            systemImage: "speedometer",
            value: value,
            range: 0.1...8,
            step: 0.05,
            format: { $0.formatted(.number.precision(.fractionLength(2))) + "×" },
            onBegan: {
                speedEditSession = viewModel.beginSelectedSpeedEditAtPlayhead()
            },
            onChanged: { speed in
                guard let speedEditSession else { return }
                _ = viewModel.setSelectedSpeed(
                    speed,
                    in: speedEditSession,
                    interactive: true
                )
            },
            onEnded: finishSpeedEditIfNeeded
        )
        .disabled(!isEnabled && speedEditSession == nil)
    }

    private func finishSpeedEditIfNeeded() {
        guard speedEditSession != nil else { return }
        speedEditSession = nil
        viewModel.finishInteractiveEdit()
    }
}

struct MaskWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let item: TimelineItem?

    var body: some View {
        TimelineItemWorkspaceShell(
            viewModel: viewModel,
            item: item,
            title: "Mask",
            systemImage: "circle.lefthalf.filled"
        ) { item, isEnabled in
            if let visuals = item.editableVisuals, supportsMask(item) {
                let mask = visuals.mask
                VStack(spacing: 14) {
                    Toggle(
                        "Enable mask",
                        isOn: Binding(
                            get: { mask != nil },
                            set: { viewModel.setSelectedMaskEnabled($0) }
                        )
                    )
                    .font(.callout.weight(.medium))
                    .tint(MotionaryTheme.accent)
                    .disabled(!isEnabled)

                    if let mask {
                        Picker(
                            "Shape",
                            selection: Binding(
                                get: { mask.shape },
                                set: { viewModel.setSelectedMaskShape($0) }
                            )
                        ) {
                            Label("Rectangle", systemImage: "rectangle").tag(ItemMask.Shape.rectangle)
                            Label("Ellipse", systemImage: "circle").tag(ItemMask.Shape.ellipse)
                        }
                        .pickerStyle(.segmented)
                        .disabled(!isEnabled)

                        maskScrubber(
                            title: "Horizontal inset",
                            value: mask.insetX,
                            range: 0...0.48,
                            update: { viewModel.setSelectedMaskInsets(horizontal: $0, interactive: true) }
                        )
                        .disabled(!isEnabled)
                        maskScrubber(
                            title: "Vertical inset",
                            value: mask.insetY,
                            range: 0...0.48,
                            update: { viewModel.setSelectedMaskInsets(vertical: $0, interactive: true) }
                        )
                        .disabled(!isEnabled)
                        maskScrubber(
                            title: "Feather",
                            value: mask.feather,
                            range: 0...0.25,
                            update: { viewModel.setSelectedMaskInsets(feather: $0, interactive: true) }
                        )
                        .disabled(!isEnabled)
                    }
                }
            } else {
                EditorWorkspaceMessage(
                    text: "Masks are available for visual media, shapes, and text.",
                    systemImage: "circle.lefthalf.filled"
                )
            }
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func maskScrubber(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        update: @escaping (Double) -> Void
    ) -> some View {
        EditorValueScrubber(
            title: title,
            systemImage: "slider.horizontal.3",
            value: value,
            range: range,
            step: 0.01,
            format: percent,
            onBegan: viewModel.beginInteractiveEdit,
            onChanged: update,
            onEnded: { viewModel.finishInteractiveEdit() }
        )
    }
}

private struct TimelineItemWorkspaceShell<Content: View>: View {
    @ObservedObject var viewModel: EditorViewModel
    let item: TimelineItem?
    let title: String
    let systemImage: String
    @ViewBuilder let content: (TimelineItem, Bool) -> Content

    var body: some View {
        let isEnabled = item.map(isWorkspaceEnabled) ?? false
        EditorWorkspaceShell(
            title: title,
            systemImage: systemImage,
            isEnabled: isEnabled,
            emptyState: item == nil
                ? EditorWorkspaceEmptyState(title: "Select a clip", systemImage: "cursorarrow.click.2")
                : nil
        ) {
            if let item {
                content(item, isEnabled)
            }
        }
    }

    private func isWorkspaceEnabled(_ item: TimelineItem) -> Bool {
        viewModel.selectedTimelineItemID == item.id
            && viewModel.currentTime >= item.timelineStart
            && viewModel.currentTime < item.timelineEnd
    }
}

private func supportsMask(_ item: TimelineItem) -> Bool {
    switch item {
    case .media(let item): item.mediaType != .audio
    case .shape, .text: true
    case .caption, .adjustment, .compound: false
    }
}
