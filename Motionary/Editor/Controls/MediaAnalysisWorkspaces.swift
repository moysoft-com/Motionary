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
    @State private var brushSession: BackgroundBrushSession?

    var body: some View {
        EditorWorkspaceShell(
            title: "Remove BG", systemImage: "person.crop.square", isEnabled: isEnabled,
            emptyState: mediaItem == nil ? EditorWorkspaceEmptyState(
                title: "Select an image or video clip to remove its background.",
                systemImage: "person.crop.square"
            ) : nil,
            disablesContentWhenUnavailable: true
        ) {
            VStack(spacing: 14) {
                EditorWorkspaceHorizontalStrip {
                    ForEach(BackgroundRemovalMode.allCases) { mode in
                        EditorWorkspaceTileButton(
                            title: mode.title, systemImage: mode.systemImage,
                            isSelected: settings?.mode == mode
                        ) { viewModel.setSelectedBackgroundRemovalMode(mode) }
                        .disabled(viewModel.isPerformingLongTask)
                    }
                }
                EditorWorkspaceOnOffControl(
                    title: "Remove background", isOn: settings != nil,
                    isEnabled: !viewModel.isPerformingLongTask
                ) { enabled in
                    if enabled { viewModel.enableSelectedBackgroundRemoval() }
                    else { viewModel.disableSelectedBackgroundRemoval() }
                }
                if let settings {
                    if settings.mode == .automatic {
                        HStack {
                            Label(viewModel.selectedBackgroundRemovalArtifactIsReady ? "Ready" : "Retry needed",
                                systemImage: viewModel.selectedBackgroundRemovalArtifactIsReady
                                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(MotionaryDesign.Typography.statusLabel)
                                .foregroundStyle(MotionaryTheme.textSecondary)
                            Spacer()
                            EditorWorkspaceIconButton(systemName: "arrow.clockwise",
                                accessibilityLabel: "Regenerate matte",
                                isEnabled: !viewModel.isPerformingLongTask
                            ) { viewModel.regenerateSelectedBackgroundRemoval() }
                        }
                    }
                    if settings.mode == .chromaKey { chromaControls(settings) }
                    if settings.mode == .custom {
                        EditorWorkspaceCommandButton(title: "Edit cutout", systemImage: "paintbrush.pointed") {
                            openBrush(settings)
                        }
                        EditorWorkspaceMessage(
                            text: "Brush to erase or restore areas. On videos, your cutout stays fixed across the clip.",
                            systemImage: "hand.draw"
                        )
                    }
                    backgroundScrubber(title: "Edge", systemImage: "circle.dotted",
                        value: settings.edgeRefinement, range: -1...1,
                        format: { String(format: "%+.0f%%", $0 * 100) }
                    ) { viewModel.setSelectedBackgroundRemovalSettings(edgeRefinement: $0, interactive: true) }
                    backgroundScrubber(title: "Feather", systemImage: "circle.lefthalf.filled",
                        value: settings.feather, range: 0...1
                    ) { viewModel.setSelectedBackgroundRemovalSettings(feather: $0, interactive: true) }
                    EditorWorkspaceOnOffControl(title: "Invert cutout", isOn: settings.isInverted) {
                        viewModel.setSelectedBackgroundRemovalSettings(isInverted: $0)
                    }
                } else {
                    EditorWorkspaceMessage(
                        text: "Isolate a subject automatically, key out a color, or draw your own cutout.",
                        systemImage: "person.crop.square"
                    )
                }
            }
        }
        .sheet(item: $brushSession) { session in
            BackgroundBrushEditor(session: session) { strokes in
                guard viewModel.selectedTimelineItemID == session.id else { return }
                viewModel.setSelectedBackgroundRemovalSettings(strokes: strokes)
            }
        }
    }

    private var settings: BackgroundRemovalSettings? { mediaItem?.visuals.backgroundRemoval }
    private var mediaItem: MediaTimelineItem? {
        guard case .media(let media) = item,
            media.mediaType == .image || media.mediaType == .video else { return nil }
        return media
    }
    private var isEnabled: Bool {
        guard let item else { return false }
        return viewModel.selectedTimelineItemID == item.id
            && viewModel.currentTime >= item.timelineStart && viewModel.currentTime < item.timelineEnd
    }

    private func openBrush(_ settings: BackgroundRemovalSettings) {
        guard let media = mediaItem, let asset = viewModel.project.mediaLibrary[media.mediaID] else { return }
        brushSession = BackgroundBrushSession(
            id: media.id,
            url: viewModel.projectStore.resolvedMediaURL(asset.url, projectID: viewModel.projectID),
            sourceTime: media.sourceRange.start + media.speedMap.sourceTime(
                at: max(viewModel.currentTime - media.timelineStart, 0),
                sourceDuration: media.sourceRange.duration
            ), settings: settings
        )
    }

    private func chromaControls(_ settings: BackgroundRemovalSettings) -> some View {
        VStack(spacing: 14) {
            EditorWorkspaceSection(title: "Key color") {
                HStack(spacing: 8) {
                    keyPreset("Green", color: RGBAColor(red: 0, green: 1, blue: 0), settings: settings)
                    keyPreset("Blue", color: RGBAColor(red: 0, green: 0, blue: 1), settings: settings)
                    keyPreset("White", color: .white, settings: settings)
                    keyPreset("Black", color: .black, settings: settings)
                }
                EditorWorkspaceColorRow(title: "Custom color", color: settings.keyColor.swiftUIColor,
                    systemImage: "eyedropper", supportsOpacity: false
                ) { viewModel.setSelectedBackgroundRemovalSettings(keyColor: RGBAColor($0)) }
            }
            backgroundScrubber(title: "Tolerance", systemImage: "scope",
                value: settings.tolerance, range: 0...1
            ) { viewModel.setSelectedBackgroundRemovalSettings(tolerance: $0, interactive: true) }
            backgroundScrubber(title: "Softness", systemImage: "drop.halffull",
                value: settings.softness, range: 0...1
            ) { viewModel.setSelectedBackgroundRemovalSettings(softness: $0, interactive: true) }
            backgroundScrubber(title: "Spill", systemImage: "paintbrush",
                value: settings.spillSuppression, range: 0...1
            ) { viewModel.setSelectedBackgroundRemovalSettings(spillSuppression: $0, interactive: true) }
        }
    }

    private func keyPreset(_ title: String, color: RGBAColor, settings: BackgroundRemovalSettings) -> some View {
        EditorWorkspaceSelectionButton(title: title, systemImage: nil, isSelected: settings.keyColor == color) {
            viewModel.setSelectedBackgroundRemovalSettings(keyColor: color)
        }
    }

    private func backgroundScrubber(
        title: String, systemImage: String, value: Double, range: ClosedRange<Double>,
        format: @escaping (Double) -> String = { "\(Int(($0 * 100).rounded()))%" },
        update: @escaping (Double) -> Void
    ) -> some View {
        EditorValueScrubber(title: title, systemImage: systemImage, value: value,
            range: range, step: 0.01, format: format,
            onBegan: viewModel.beginInteractiveEdit, onChanged: update,
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
