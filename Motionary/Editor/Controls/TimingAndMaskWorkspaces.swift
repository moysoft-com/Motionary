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

                        EditorWorkspaceOnOffControl(
                            title: "Pitch follows speed",
                            isOn: media.pitchFollowsSpeed,
                            isEnabled: isEnabled,
                            onChange: viewModel.setSelectedPitchFollowsSpeed
                        )

                        EditorWorkspaceOnOffControl(
                            title: "Ripple following clips",
                            isOn: viewModel.isRippleEditingEnabled,
                            isEnabled: isEnabled
                        ) { viewModel.isRippleEditingEnabled = $0 }

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
            systemImage: "circle.dashed"
        ) { item, isEnabled in
            if let visuals = item.editableVisuals, supportsMask(item) {
                let mask = visuals.mask
                let unitSpace = maskUnitSpace(for: item)
                VStack(spacing: 14) {
                    EditorWorkspaceSection(title: "Preset") {
                        EditorWorkspaceHorizontalStrip {
                            ForEach(MaskPreset.allCases) { preset in
                                presetButton(
                                    preset,
                                    mask: mask,
                                    unitSpace: unitSpace,
                                    isEnabled: isEnabled
                                )
                            }
                        }
                    }

                    if let mask {
                        if mask.shape != .bar && mask.shape != .split {
                            maskScrubber(
                                title: "Width",
                                value: mask.widthScale * unitSpace.width,
                                range: 0...unitSpace.width,
                                update: {
                                    viewModel.setSelectedMaskSize(
                                        widthScale: $0 / max(unitSpace.width, 0.000_001),
                                        interactive: true
                                    )
                                }
                            )
                            .disabled(!isEnabled)
                        }
                        if mask.shape != .split {
                            maskScrubber(
                                title: mask.shape == .bar ? "Thickness" : "Height",
                                value: mask.heightScale * unitSpace.height,
                                range: 0...unitSpace.height,
                                update: {
                                    viewModel.setSelectedMaskSize(
                                        heightScale: $0 / max(unitSpace.height, 0.000_001),
                                        interactive: true
                                    )
                                }
                            )
                            .disabled(!isEnabled)
                        }
                        if mask.shape != .ellipse && mask.shape != .heart
                            && mask.shape != .bar && mask.shape != .split
                        {
                            let maximumRoundness = min(unitSpace.width, unitSpace.height) * 0.5
                            maskScrubber(
                                title: "Roundness",
                                value: mask.roundnessScale * maximumRoundness,
                                range: 0...maximumRoundness,
                                update: {
                                    viewModel.setSelectedMaskGeometry(
                                        roundnessScale: $0 / max(maximumRoundness, 0.000_001),
                                        interactive: true
                                    )
                                }
                            )
                            .disabled(!isEnabled)
                        }
                        if mask.shape == .bar || mask.shape == .split {
                            let maximumOffset = unitSpace.height * 0.5
                            maskScrubber(
                                title: "Offset",
                                value: mask.offsetScale * maximumOffset,
                                range: -maximumOffset...maximumOffset,
                                update: {
                                    viewModel.setSelectedMaskGeometry(
                                        offsetScale: $0 / max(maximumOffset, 0.000_001),
                                        interactive: true
                                    )
                                }
                            )
                            .disabled(!isEnabled)
                        }
                        maskScrubber(
                            title: "Rotation",
                            value: mask.rotationDegrees,
                            range: -180...180,
                            systemImage: "rotate.right",
                            format: { "\(Int($0.rounded()))°" },
                            update: {
                                viewModel.setSelectedMaskGeometry(
                                    rotationDegrees: $0,
                                    interactive: true
                                )
                            }
                        )
                        .disabled(!isEnabled)
                        maskScrubber(
                            title: "Feather",
                            value: mask.featherScale * EditorUnitSpace.referenceUnits,
                            range: 0...min(unitSpace.width, unitSpace.height),
                            update: {
                                viewModel.setSelectedMaskSize(
                                    featherScale: $0 / EditorUnitSpace.referenceUnits,
                                    interactive: true
                                )
                            }
                        )
                        .disabled(!isEnabled)
                        EditorWorkspaceOnOffControl(
                            title: "Invert",
                            isOn: mask.isInverted,
                            isEnabled: isEnabled
                        ) {
                            viewModel.setSelectedMaskGeometry(isInverted: $0)
                        }
                    }
                }
            } else {
                EditorWorkspaceMessage(
                    text: "Masks are available for visual media, shapes, and text.",
                    systemImage: "circle.dashed"
                )
            }
        }
    }

    private func presetButton(
        _ preset: MaskPreset,
        mask: ItemMask?,
        unitSpace: EditorUnitSpace,
        isEnabled: Bool
    ) -> some View {
        let isSelected = preset.matches(mask, in: unitSpace)
        return EditorWorkspaceTileButton(
            title: preset.title,
            systemImage: preset.systemImage,
            isSelected: isSelected,
            isEnabled: isEnabled
        ) {
            viewModel.setSelectedMask(preset.mask(in: unitSpace))
        }
    }

    private func maskScrubber(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        systemImage: String = "slider.horizontal.3",
        format: @escaping (Double) -> String = { "\(Int($0.rounded()))" },
        update: @escaping (Double) -> Void
    ) -> some View {
        EditorValueScrubber(
            title: title,
            systemImage: systemImage,
            value: value,
            range: range,
            step: 1,
            format: format,
            onBegan: viewModel.beginInteractiveEdit,
            onChanged: update,
            onEnded: { viewModel.finishInteractiveEdit() }
        )
    }

    private func maskUnitSpace(for item: TimelineItem) -> EditorUnitSpace {
        let canvasSize = viewModel.project.renderSettings.size
        let size: CGSize
        switch item {
        case .media:
            if let clip = item.legacyClip(),
                let naturalSize = viewModel.project.naturalSize(for: clip)?.displaySafeSize
            {
                size = naturalSize
            } else {
                size = canvasSize
            }
        case .shape(let shape):
            let localTime = max(viewModel.currentTime - shape.timelineStart, 0)
            size = CGSize(
                width: CGFloat(shape.shape.width.value(at: localTime)),
                height: CGFloat(shape.shape.height.value(at: localTime))
            )
        case .text(let text):
            size =
                TextLayerRenderer.geometry(
                    for: text,
                    renderSize: canvasSize,
                    renderScale: 1,
                    at: max(viewModel.currentTime - text.timelineStart, 0)
                ).layerSize
        case .caption, .adjustment, .compound:
            size = canvasSize
        }
        return EditorUnitSpace(size: size)
    }
}

private enum MaskPreset: String, CaseIterable, Identifiable {
    case none
    case rectangle
    case circle
    case diamond
    case triangle
    case star
    case heart
    case bar
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .rectangle: "Rectangle"
        case .circle: "Circle"
        case .diamond: "Diamond"
        case .triangle: "Triangle"
        case .star: "Star"
        case .heart: "Heart"
        case .bar: "Bar"
        case .split: "Split"
        }
    }

    var systemImage: String {
        switch self {
        case .none: "nosign"
        case .rectangle: "rectangle"
        case .circle: "circle"
        case .diamond: "diamond"
        case .triangle: "triangle"
        case .star: "star"
        case .heart: "heart"
        case .bar: "minus"
        case .split: "square.lefthalf.filled"
        }
    }

    func mask(in space: EditorUnitSpace) -> ItemMask? {
        guard self != .none else { return nil }
        let shape: ItemMask.Shape
        let widthScale: Double
        let heightScale: Double
        switch self {
        case .circle, .star, .heart:
            let side = min(space.width, space.height)
            widthScale = side / max(space.width, 0.000_001)
            heightScale = side / max(space.height, 0.000_001)
        case .rectangle, .diamond, .triangle, .split:
            widthScale = 1
            heightScale = 1
        case .bar:
            widthScale = 1
            heightScale = 0.2
        case .none:
            return nil
        }
        switch self {
        case .rectangle: shape = .rectangle
        case .circle: shape = .ellipse
        case .diamond: shape = .diamond
        case .triangle: shape = .triangle
        case .star: shape = .star
        case .heart: shape = .heart
        case .bar: shape = .bar
        case .split: shape = .split
        case .none: return nil
        }
        return ItemMask(
            shape: shape,
            widthScale: widthScale,
            heightScale: heightScale
        )
    }

    func matches(_ mask: ItemMask?, in space: EditorUnitSpace) -> Bool {
        guard let expected = self.mask(in: space) else { return mask == nil }
        guard let mask else { return false }
        let shapeMatches =
            self == .rectangle
            ? mask.shape == .rectangle || mask.shape == .roundedRectangle
            : mask.shape == expected.shape
        return shapeMatches
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
