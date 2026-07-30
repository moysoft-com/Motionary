// Editor toolbar and canvas-ratio controls.

import PhotosUI
import SwiftUI

struct CoreToolBar: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var selectedMediaItems: [PhotosPickerItem]
    @Binding var selectedReplacementItem: PhotosPickerItem?
    @Binding var isAudioVideoPickerPresented: Bool
    @Binding var isAudioFileImporterPresented: Bool
    @Binding var activePanel: CoreEditorPanel
    @Binding var propertyContextClipID: UUID?
    @Binding var graphReturnPanel: CoreEditorPanel
    @Binding var activeEffectWorkspaceID: UUID?
    @State private var extractableMediaID: MediaID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MotionaryDesign.Spacing.sm) {
                if let selectedItem = viewModel.selectedTimelineItem {
                    selectedLayerTool(for: selectedItem)
                } else {
                    PhotosPicker(selection: $selectedMediaItems, matching: .any(of: [.images, .videos])) {
                        CoreToolButtonContent(systemName: "plus", title: "Media", isProminent: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isPerformingLongTask)
                    .accessibilityLabel("Import media")

                    ShapeToolMenu(viewModel: viewModel)

                    CoreToolButton(systemName: "textformat", title: "Text") {
                        guard let itemID = viewModel.addText() else { return }
                        propertyContextClipID = itemID
                        activePanel = .text
                    }
                    .accessibilityLabel("Add text")

                    AudioImportMenu(
                        viewModel: viewModel,
                        isAudioVideoPickerPresented: $isAudioVideoPickerPresented,
                        isAudioFileImporterPresented: $isAudioFileImporterPresented
                    )
                }

                if viewModel.selectedTimelineItem != nil {
                    Divider()
                        .frame(height: MotionaryDesign.Control.compactHeight)
                        .overlay(MotionaryTheme.surfaceStrong)

                    if isTextSelected {
                        CoreToolButton(
                            systemName: "textformat.size",
                            title: "Type",
                            isSelected: activePanel == .textType
                        ) {
                            openTextPanel(.textType)
                        }
                        CoreToolButton(
                            systemName: "paintbrush",
                            title: "Style",
                            isSelected: activePanel == .textStyle
                        ) {
                            openTextPanel(.textStyle)
                        }
                        CoreToolButton(
                            systemName: "sparkles",
                            title: "Motion",
                            isSelected: activePanel == .textMotion || activePanel == .textMotionGraph
                        ) {
                            openTextPanel(.textMotion)
                        }
                    }

                    if supportsTransform {
                        CoreToolButton(
                            systemName: propertyToolSystemName(for: .transform, fallback: "crop.rotate"),
                            title: propertyToolTitle(for: .transform, fallback: "Transform"),
                            isSelected: isPropertyToolSelected(.transform)
                        ) {
                            if activePanel == .graph, graphReturnPanel == .transform {
                                viewModel.graphSegment = nil
                                activePanel = .transform
                                return
                            }
                            propertyContextClipID = viewModel.selectedTimelineItemID
                            activePanel = activePanel == .transform ? .timeline : .transform
                        }
                    }

                    CoreToolButton(systemName: "scissors", title: "Split") {
                        if let splitClipID = viewModel.splitSelectedClip(),
                            activePanel.isPropertyPanel
                        {
                            propertyContextClipID = splitClipID
                        }
                    }

                    CoreToolButton(systemName: "trash", title: "Delete") {
                        viewModel.deleteSelectedClip()
                    }

                    if canExtractAudioFromSelectedClip {
                        CoreToolButton(
                            systemName: "waveform.badge.plus",
                            title: "Extract"
                        ) {
                            viewModel.extractAudioFromSelectedClip()
                        }
                        .accessibilityLabel("Extract audio")
                    }

                    if supportsSpeed {
                        CoreToolButton(
                            systemName: propertyToolSystemName(for: .speed, fallback: "speedometer"),
                            title: propertyToolTitle(for: .speed, fallback: "Speed"),
                            isSelected: isPropertyToolSelected(.speed)
                        ) {
                            openPropertyPanel(.speed)
                        }
                    }

                    if supportsMask {
                        CoreToolButton(
                            systemName: "circle.dashed",
                            title: "Mask",
                            isSelected: isPropertyToolSelected(.mask)
                        ) {
                            openPropertyPanel(.mask)
                        }
                    }

                    if supportsBackgroundRemoval {
                        CoreToolButton(
                            systemName: "person.crop.square",
                            title: "BG",
                            isSelected: isPropertyToolSelected(.removeBackground)
                        ) {
                            openPropertyPanel(.removeBackground)
                        }
                    }

                    if supportsBlend {
                        CoreToolButton(
                            systemName: "square.stack.3d.up.fill",
                            title: "Blend",
                            isSelected: isPropertyToolSelected(.blend)
                        ) {
                            openPropertyPanel(.blend)
                        }
                    }

                    if supportsAutoBeats {
                        CoreToolButton(
                            systemName: "metronome",
                            title: "Beats",
                            isSelected: isPropertyToolSelected(.autoBeats)
                        ) {
                            openPropertyPanel(.autoBeats)
                        }
                    }

                    if supportsVisualAdjustments {
                        CoreToolButton(
                            systemName: propertyToolSystemName(for: .adjust, fallback: "slider.horizontal.3"),
                            title: propertyToolTitle(for: .adjust, fallback: "Adjust"),
                            isSelected: isPropertyToolSelected(.adjust)
                        ) {
                            openPropertyPanel(.adjust)
                        }

                        CoreToolButton(
                            systemName: propertyToolSystemName(for: .effects, fallback: "sparkles.2"),
                            title: propertyToolTitle(for: .effects, fallback: "Effects"),
                            isSelected: isPropertyToolSelected(.effects)
                        ) {
                            openEffectsPanel()
                        }
                    }

                    if hasAudioControls && !isAudioSelected {
                        CoreToolButton(
                            systemName: propertyToolSystemName(for: .audio, fallback: "speaker.wave.2"),
                            title: propertyToolTitle(for: .audio, fallback: "Audio"),
                            isSelected: isPropertyToolSelected(.audio)
                        ) {
                            openPropertyPanel(.audio)
                        }
                    }

                    CoreToolButton(systemName: "plus.square.on.square", title: "Duplicate") {
                        viewModel.duplicateSelectedClip()
                    }
                }

                Divider()
                    .frame(height: MotionaryDesign.Control.compactHeight)
                    .overlay(MotionaryTheme.surfaceStrong)

                CoreToolButton(
                    systemName: "aspectratio",
                    title: "Canvas",
                    isSelected: activePanel == .canvas
                ) {
                    propertyContextClipID = nil
                    activePanel = activePanel == .canvas ? .timeline : .canvas
                }
                .accessibilityLabel("Canvas settings")
            }
            .padding(MotionaryDesign.Spacing.sm)
        }
        .clipShape(RoundedRectangle(cornerRadius: MotionaryDesign.Radius.panel, style: .continuous))
        .motionaryGlass(cornerRadius: MotionaryDesign.Radius.panel)
        .task(id: audioExtractionTaskID) {
            await refreshAudioExtractionAvailability()
        }
    }

    private func isPropertyToolSelected(_ panel: CoreEditorPanel) -> Bool {
        activePanel == panel || (activePanel == .graph && graphReturnPanel == panel)
    }

    @ViewBuilder
    private func selectedLayerTool(for item: TimelineItem) -> some View {
        switch item {
        case .media(let media) where media.mediaType == .audio:
            CoreToolButton(
                systemName: "speaker.wave.2",
                title: "Edit",
                isSelected: true
            ) {
                openPropertyPanel(.audio)
            }
        case .media:
            PhotosPicker(
                selection: $selectedReplacementItem,
                matching: .any(of: [.images, .videos])
            ) {
                CoreToolButtonContent(
                    systemName: "arrow.triangle.2.circlepath",
                    title: "Replace",
                    isProminent: true
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isPerformingLongTask)
            .accessibilityLabel("Replace selected media")
        case .shape:
            CoreToolButton(
                systemName: "slider.horizontal.3",
                title: "Edit",
                isSelected: true
            ) {
                propertyContextClipID = viewModel.selectedTimelineItemID
                activePanel = activePanel == .shape ? .timeline : .shape
            }
        case .text:
            CoreToolButton(
                systemName: "pencil",
                title: "Edit",
                isSelected: true
            ) {
                propertyContextClipID = viewModel.selectedTimelineItemID
                activePanel = activePanel == .text ? .timeline : .text
            }
        case .caption, .adjustment, .compound:
            EmptyView()
        }
    }

    private var hasAudioControls: Bool {
        guard case .media(let item) = viewModel.selectedTimelineItem else { return false }
        return item.mediaType == .audio || item.mediaType == .video
    }

    private var isTextSelected: Bool {
        guard case .text = viewModel.selectedTimelineItem else { return false }
        return true
    }

    private var isAudioSelected: Bool {
        guard case .media(let item) = viewModel.selectedTimelineItem else { return false }
        return item.mediaType == .audio
    }

    private var audioExtractionCandidate: TimelineClip? {
        guard let clip = viewModel.selectedClip,
            clip.mediaType == .video,
            let location = viewModel.project.clipLocation(id: clip.id),
            viewModel.project.tracks[location.track].kind != .audio
        else { return nil }
        return clip
    }

    private var audioExtractionTaskID: String {
        audioExtractionCandidate?.mediaID.rawValue.uuidString ?? "none"
    }

    private var canExtractAudioFromSelectedClip: Bool {
        guard let clip = audioExtractionCandidate else { return false }
        return extractableMediaID == clip.mediaID
    }

    private func refreshAudioExtractionAvailability() async {
        extractableMediaID = nil
        guard let clip = audioExtractionCandidate else { return }
        let storedURL = viewModel.project.mediaURL(for: clip)
        let url = viewModel.projectStore.resolvedMediaURL(
            storedURL,
            projectID: viewModel.projectID
        )
        guard let metadata = try? await MediaAssetCache.shared.metadata(for: url),
            !Task.isCancelled,
            metadata.audioTrack != nil,
            audioExtractionCandidate?.mediaID == clip.mediaID
        else { return }
        extractableMediaID = clip.mediaID
    }

    private var supportsTransform: Bool {
        switch viewModel.selectedTimelineItem {
        case .media(let item):
            item.mediaType != .audio
        case .shape, .text:
            true
        default:
            false
        }
    }

    private var supportsVisualAdjustments: Bool {
        switch viewModel.selectedTimelineItem {
        case .media(let item):
            item.mediaType != .audio
        case .shape:
            true
        default:
            false
        }
    }

    private var supportsSpeed: Bool {
        guard case .media(let item) = viewModel.selectedTimelineItem else { return false }
        return item.mediaType == .video || item.mediaType == .audio
    }

    private var supportsMask: Bool {
        switch viewModel.selectedTimelineItem {
        case .media(let item):
            item.mediaType != .audio
        case .shape, .text:
            true
        default:
            false
        }
    }

    private var supportsBackgroundRemoval: Bool {
        guard case .media(let item) = viewModel.selectedTimelineItem else { return false }
        return item.mediaType == .image || item.mediaType == .video
    }

    private var supportsBlend: Bool {
        switch viewModel.selectedTimelineItem {
        case .media(let item):
            item.mediaType != .audio
        case .shape, .text:
            true
        default:
            false
        }
    }

    private var supportsAutoBeats: Bool {
        guard case .media(let item) = viewModel.selectedTimelineItem else { return false }
        return item.mediaType == .audio
    }

    private func openTextPanel(_ panel: CoreEditorPanel) {
        propertyContextClipID = viewModel.selectedTimelineItemID
        if panel == .textMotion, activePanel == .textMotionGraph {
            activePanel = .textMotion
            return
        }
        activePanel = activePanel == panel ? .timeline : panel
    }

    private func openPropertyPanel(_ panel: CoreEditorPanel) {
        if activePanel == .graph, graphReturnPanel == panel {
            viewModel.graphSegment = nil
            activePanel = panel
            return
        }
        propertyContextClipID = viewModel.selectedTimelineItemID
        activePanel = activePanel == panel ? .timeline : panel
    }

    private func openEffectsPanel() {
        if activePanel == .effects, activeEffectWorkspaceID != nil {
            activeEffectWorkspaceID = nil
            viewModel.activeKeyframeTarget = nil
            return
        }
        openPropertyPanel(.effects)
    }

    private func propertyToolSystemName(
        for panel: CoreEditorPanel,
        fallback: String
    ) -> String {
        activePanel == .graph && graphReturnPanel == panel
            ? "point.topleft.down.curvedto.point.bottomright.up"
            : fallback
    }

    private func propertyToolTitle(
        for panel: CoreEditorPanel,
        fallback: String
    ) -> String {
        activePanel == .graph && graphReturnPanel == panel ? "Graphs" : fallback
    }
}

private struct ShapeToolMenu: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        Menu {
            ForEach(ClipShapeKind.allCases) { kind in
                Button {
                    viewModel.addShape(kind)
                } label: {
                    Label(kind.title, systemImage: kind.systemImage)
                }
            }
        } label: {
            CoreToolButtonContent(systemName: "square.on.circle", title: "Shape")
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isPerformingLongTask)
        .accessibilityLabel("Add shape")
    }
}

private struct AudioImportMenu: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var isAudioVideoPickerPresented: Bool
    @Binding var isAudioFileImporterPresented: Bool

    var body: some View {
        Menu {
            Button {
                isAudioVideoPickerPresented = true
            } label: {
                Label("From Video Library", systemImage: "photo.on.rectangle")
            }

            Button {
                isAudioFileImporterPresented = true
            } label: {
                Label("From Files", systemImage: "folder")
            }
        } label: {
            CoreToolButtonContent(systemName: "waveform.badge.plus", title: "Audio")
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isPerformingLongTask)
        .accessibilityLabel("Import audio")
    }
}
