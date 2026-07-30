// Workspaces for blend modes, foreground isolation, and automatic audio beats.

import Foundation
import SwiftUI

struct BlendWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let item: TimelineItem?

    var body: some View {
        EditorWorkspaceShell(
            title: "Blend",
            systemImage: "square.stack.3d.up.fill",
            isEnabled: isEnabled,
            emptyState: selectedMode == nil
                ? EditorWorkspaceEmptyState(
                    title: "Select a visual layer to choose its blend mode.",
                    systemImage: "square.stack.3d.up.slash"
                )
                : nil,
            disablesContentWhenUnavailable: true
        ) {
            VStack(spacing: 14) {
                EditorWorkspaceSection(title: "Mode") {
                    EditorWorkspaceHorizontalStrip {
                        ForEach(BlendMode.allCases) { mode in
                            blendTile(mode)
                        }
                    }
                }

                EditorValueScrubber(
                    title: "Intensity",
                    systemImage: "dial.low",
                    value: selectedIntensity ?? 1,
                    range: 0...1,
                    step: 0.01,
                    format: { "\(Int(($0 * 100).rounded()))%" },
                    onBegan: viewModel.beginInteractiveEdit,
                    onChanged: { viewModel.setSelectedBlendIntensity($0, interactive: true) },
                    onEnded: { viewModel.finishInteractiveEdit() }
                )
            }
        }
    }

    private var selectedMode: BlendMode? {
        item?.editableVisuals?.blendMode
    }

    private var selectedIntensity: Double? {
        item?.editableVisuals?.blendIntensity
    }

    private var isEnabled: Bool {
        guard let item else { return false }
        return viewModel.selectedTimelineItemID == item.id
            && viewModel.currentTime >= item.timelineStart
            && viewModel.currentTime < item.timelineEnd
    }

    private func blendTile(_ mode: BlendMode) -> some View {
        let isSelected = selectedMode == mode
        return EditorWorkspaceTileButton(
            title: mode.shortTitle,
            systemImage: mode.systemImage,
            isSelected: isSelected
        ) {
            viewModel.setSelectedBlendMode(mode)
        }
    }
}

struct RemoveBackgroundWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let item: TimelineItem?

    var body: some View {
        EditorWorkspaceShell(
            title: "Remove BG",
            systemImage: "person.crop.square",
            isEnabled: isEnabled,
            emptyState: mediaItem == nil
                ? EditorWorkspaceEmptyState(
                    title: "Select an image or video clip to remove its background.",
                    systemImage: "person.crop.square"
                )
                : nil,
            disablesContentWhenUnavailable: true
        ) {
            VStack(spacing: 14) {
                let isRemovalEnabled = mediaItem?.visuals.backgroundRemoval != nil
                EditorWorkspaceOnOffControl(
                    title: "Remove background",
                    isOn: isRemovalEnabled,
                    isEnabled: isRemovalEnabled || !viewModel.isPerformingLongTask
                ) { enabled in
                    if enabled {
                        viewModel.enableSelectedBackgroundRemoval()
                    } else {
                        viewModel.disableSelectedBackgroundRemoval()
                    }
                }

                if let settings = mediaItem?.visuals.backgroundRemoval {
                    HStack(spacing: 10) {
                        Label(
                            viewModel.selectedBackgroundRemovalArtifactIsReady ? "Ready" : "Retry needed",
                            systemImage: viewModel.selectedBackgroundRemovalArtifactIsReady
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(MotionaryDesign.Typography.statusLabel)
                        .foregroundStyle(
                            viewModel.selectedBackgroundRemovalArtifactIsReady
                                ? MotionaryTheme.textSecondary
                                : Color.orange
                        )

                        Spacer()

                        EditorWorkspaceIconButton(
                            systemName: "arrow.clockwise",
                            accessibilityLabel: viewModel.selectedBackgroundRemovalArtifactIsReady
                                ? "Regenerate matte"
                                : "Retry matte",
                            isEnabled: !viewModel.isPerformingLongTask
                        ) {
                            viewModel.regenerateSelectedBackgroundRemoval()
                        }

                    }
                    backgroundScrubber(
                        title: "Edge",
                        systemImage: "circle.dotted",
                        value: settings.edgeRefinement,
                        range: -1...1,
                        format: { String(format: "%+.0f%%", $0 * 100) },
                        update: {
                            viewModel.setSelectedBackgroundRemovalSettings(
                                edgeRefinement: $0,
                                interactive: true
                            )
                        }
                    )

                    backgroundScrubber(
                        title: "Feather",
                        systemImage: "circle.lefthalf.filled",
                        value: settings.feather,
                        range: 0...1,
                        format: { "\(Int(($0 * 100).rounded()))%" },
                        update: {
                            viewModel.setSelectedBackgroundRemovalSettings(
                                feather: $0,
                                interactive: true
                            )
                        }
                    )
                } else {
                    EditorWorkspaceMessage(
                        text: "Foreground subjects are detected locally. The original media stays untouched.",
                        systemImage: "person.crop.square"
                    )
                }
            }
        }
    }

    private var mediaItem: MediaTimelineItem? {
        guard case .media(let media) = item,
            media.mediaType == .image || media.mediaType == .video
        else { return nil }
        return media
    }

    private var isEnabled: Bool {
        guard let item else { return false }
        return viewModel.selectedTimelineItemID == item.id
            && viewModel.currentTime >= item.timelineStart
            && viewModel.currentTime < item.timelineEnd
    }

    private func backgroundScrubber(
        title: String,
        systemImage: String,
        value: Double,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String,
        update: @escaping (Double) -> Void
    ) -> some View {
        EditorValueScrubber(
            title: title,
            systemImage: systemImage,
            value: value,
            range: range,
            step: 0.01,
            format: format,
            onBegan: viewModel.beginInteractiveEdit,
            onChanged: update,
            onEnded: { viewModel.finishInteractiveEdit() }
        )
        .disabled(!viewModel.selectedBackgroundRemovalArtifactIsReady)
    }
}

struct AutoBeatsWorkspaceView: View {
    @ObservedObject var viewModel: EditorViewModel
    let item: TimelineItem?

    var body: some View {
        EditorWorkspaceShell(
            title: "Beats",
            systemImage: "metronome",
            isEnabled: isEnabled,
            emptyState: audioItem == nil
                ? EditorWorkspaceEmptyState(
                    title: "Select an audio clip to analyze its beat.",
                    systemImage: "waveform.slash"
                )
                : nil,
            disablesContentWhenUnavailable: true
        ) {
            VStack(spacing: 14) {
                if let analysis = audioItem?.beatAnalysis {
                    HStack(spacing: 18) {
                        BeatMetric(title: "Tempo", value: String(format: "%.1f BPM", analysis.bpm))
                        BeatMetric(title: "Markers", value: "\(analysis.markers.count)")
                        BeatMetric(title: "Confidence", value: "\(Int(analysis.confidence * 100))%")
                    }

                    HStack(spacing: 8) {
                        EditorWorkspaceCommandButton(title: "Reanalyze", systemImage: "arrow.clockwise") {
                            viewModel.analyzeSelectedAudioBeats()
                        }

                        EditorWorkspaceCommandButton(title: "Delete", systemImage: "trash", role: .destructive) {
                            viewModel.deleteSelectedBeatMarkers()
                        }
                    }
                } else {
                    EditorWorkspaceMessage(
                        text: "Analysis creates beat markers locally and keeps existing markers if no rhythm is found.",
                        systemImage: "waveform"
                    )

                    EditorWorkspaceCommandButton(
                        title: "Analyze",
                        systemImage: "waveform.badge.magnifyingglass"
                    ) {
                        viewModel.analyzeSelectedAudioBeats()
                    }
                }
            }
            .disabled(viewModel.isPerformingLongTask)
        }
    }

    private var audioItem: MediaTimelineItem? {
        guard case .media(let media) = item, media.mediaType == .audio else { return nil }
        return media
    }

    private var isEnabled: Bool {
        guard let item else { return false }
        return viewModel.selectedTimelineItemID == item.id
            && viewModel.currentTime >= item.timelineStart
            && viewModel.currentTime < item.timelineEnd
    }

}

private struct BeatMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(MotionaryDesign.Typography.metricTitle)
                .foregroundStyle(MotionaryTheme.textSecondary)
            Text(value)
                .font(MotionaryDesign.Typography.metricValue)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension BlendMode {
    var shortTitle: String {
        switch self {
        case .normal: "Normal"
        case .darken: "Darken"
        case .multiply: "Multiply"
        case .colorBurn: "Burn"
        case .lighten: "Lighten"
        case .screen: "Screen"
        case .colorDodge: "Dodge"
        case .overlay: "Overlay"
        case .softLight: "Soft"
        case .hardLight: "Hard"
        case .difference: "Diff"
        case .exclusion: "Exclude"
        case .hue: "Hue"
        case .saturation: "Sat"
        case .color: "Color"
        case .luminosity: "Luma"
        }
    }

    var systemImage: String {
        switch self {
        case .normal: "square.on.square"
        case .darken, .multiply, .colorBurn: "moon.fill"
        case .lighten, .screen, .colorDodge: "sun.max.fill"
        case .overlay, .softLight, .hardLight: "circle.lefthalf.filled"
        case .difference, .exclusion: "plusminus"
        case .hue, .saturation, .color, .luminosity: "paintpalette.fill"
        }
    }
}
