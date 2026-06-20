// Editor toolbar and canvas-ratio controls.

import PhotosUI
import SwiftUI

struct CoreToolBar: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var selectedMediaItems: [PhotosPickerItem]
    @Binding var selectedReplacementItem: PhotosPickerItem?
    @Binding var selectedAudioVideoItem: PhotosPickerItem?
    @Binding var isAudioFileImporterPresented: Bool
    @Binding var activePanel: CoreEditorPanel
    @Binding var propertyContextClipID: UUID?
    @Binding var graphReturnPanel: CoreEditorPanel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if canReplaceSelectedMedia {
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
                    .disabled(viewModel.isImporting)
                    .accessibilityLabel("Replace selected media")
                } else {
                    PhotosPicker(selection: $selectedMediaItems, matching: .any(of: [.images, .videos])) {
                        CoreToolButtonContent(systemName: "plus", title: "Media", isProminent: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isImporting)
                    .accessibilityLabel("Import media")
                }

                if viewModel.selectedClip?.shape != nil {
                    CoreToolButton(
                        systemName: "slider.horizontal.3",
                        title: "Edit",
                        isSelected: activePanel == .shape
                    ) {
                        propertyContextClipID = viewModel.selectedClipID
                        activePanel = activePanel == .shape ? .timeline : .shape
                    }
                } else {
                    ShapeToolMenu(viewModel: viewModel)
                }
                
                AudioImportMenu(
                    viewModel: viewModel,
                    selectedAudioVideoItem: $selectedAudioVideoItem,
                    isAudioFileImporterPresented: $isAudioFileImporterPresented
                )

//                CoreToolButton(
//                    systemName: "plus.square.dashed",
//                    title: "Layer"
//                ) {
//                    viewModel.addLayer()
//                }
                
                Divider()
                    .frame(height: 38)
                    .overlay(Color.white.opacity(0.14))
                
                CoreToolButton(
                    systemName: propertyToolSystemName(for: .transform, fallback: "crop.rotate"),
                    title: propertyToolTitle(for: .transform, fallback: "Transform"),
                    isSelected: isPropertyToolSelected(.transform),
                    isDisabled: viewModel.selectedClip == nil && propertyContextClipID == nil
                ) {
                    if activePanel == .graph, graphReturnPanel == .transform {
                        viewModel.graphSegment = nil
                        activePanel = .transform
                        return
                    }
                    if let selectedClipID = viewModel.selectedClipID {
                        propertyContextClipID = selectedClipID
                    }
                    activePanel = activePanel == .transform ? .timeline : .transform
                }
                
                CoreToolButton(
                    systemName: "scissors",
                    title: "Split",
                    isDisabled: viewModel.selectedClip == nil
                ) {
                    if let splitClipID = viewModel.splitSelectedClip(),
                        activePanel.isPropertyPanel
                    {
                        propertyContextClipID = splitClipID
                    }
                }

                CoreToolButton(
                    systemName: "trash",
                    title: "Delete",
                    isDisabled: viewModel.selectedClip == nil
                ) {
                    viewModel.deleteSelectedClip()
                }
                
                CoreToolButton(
                    systemName: propertyToolSystemName(for: .adjust, fallback: "slider.horizontal.3"),
                    title: propertyToolTitle(for: .adjust, fallback: "Adjust"),
                    isSelected: isPropertyToolSelected(.adjust),
                    isDisabled: viewModel.selectedClip == nil && propertyContextClipID == nil
                ) {
                    if activePanel == .graph, graphReturnPanel == .adjust {
                        viewModel.graphSegment = nil
                        activePanel = .adjust
                        return
                    }
                    if let selectedClipID = viewModel.selectedClipID {
                        propertyContextClipID = selectedClipID
                    }
                    activePanel = activePanel == .adjust ? .timeline : .adjust
                }

                CoreToolButton(
                    systemName: propertyToolSystemName(for: .effects, fallback: "sparkles.2"),
                    title: propertyToolTitle(for: .effects, fallback: "Effects"),
                    isSelected: isPropertyToolSelected(.effects),
                    isDisabled: viewModel.selectedClip == nil && propertyContextClipID == nil
                ) {
                    if activePanel == .graph, graphReturnPanel == .effects {
                        viewModel.graphSegment = nil
                        activePanel = .effects
                        return
                    }
                    if let selectedClipID = viewModel.selectedClipID {
                        propertyContextClipID = selectedClipID
                    }
                    activePanel = activePanel == .effects ? .timeline : .effects
                }

                CoreToolButton(
                    systemName: propertyToolSystemName(for: .audio, fallback: "speaker.wave.2"),
                    title: propertyToolTitle(for: .audio, fallback: "Audio"),
                    isSelected: isPropertyToolSelected(.audio),
                    isDisabled: !hasAudioControls
                ) {
                    if activePanel == .graph, graphReturnPanel == .audio {
                        viewModel.graphSegment = nil
                        activePanel = .audio
                        return
                    }
                    if let selectedClipID = viewModel.selectedClipID {
                        propertyContextClipID = selectedClipID
                    }
                    activePanel = activePanel == .audio ? .timeline : .audio
                }

                CoreToolButton(
                    systemName: "plus.square.on.square",
                    title: "Duplicate",
                    isDisabled: viewModel.selectedClip == nil
                ) {
                    viewModel.duplicateSelectedClip()
                }

                Divider()
                    .frame(height: 38)
                    .overlay(Color.white.opacity(0.14))

                CanvasRatioMenu(viewModel: viewModel)
                CanvasColorMenu(viewModel: viewModel)
            }
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .motionaryGlass(cornerRadius: 20)
    }

    private func isPropertyToolSelected(_ panel: CoreEditorPanel) -> Bool {
        activePanel == panel || (activePanel == .graph && graphReturnPanel == panel)
    }

    private var hasAudioControls: Bool {
        let clip = viewModel.selectedClip
            ?? propertyContextClipID.flatMap { viewModel.project.clip(id: $0) }
        return clip?.mediaType == .audio || clip?.mediaType == .video
    }

    private var canReplaceSelectedMedia: Bool {
        guard let clip = viewModel.selectedClip else { return false }
        return clip.mediaType != .audio && clip.shape == nil
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
        .disabled(viewModel.isImporting)
        .accessibilityLabel("Add shape")
    }
}

private struct AudioImportMenu: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var selectedAudioVideoItem: PhotosPickerItem?
    @Binding var isAudioFileImporterPresented: Bool

    var body: some View {
        Menu {
            PhotosPicker(selection: $selectedAudioVideoItem, matching: .videos) {
                Label("From Video Library", systemImage: "photo.on.rectangle")
            }

            Button {
                viewModel.extractAudioFromSelectedClip()
            } label: {
                Label("Extract Selected Video", systemImage: "waveform.badge.plus")
            }
            .disabled(viewModel.selectedClip?.mediaType != .video)

            Button {
                isAudioFileImporterPresented = true
            } label: {
                Label("From Files", systemImage: "folder")
            }
        } label: {
            CoreToolButtonContent(systemName: "waveform.badge.plus", title: "Audio")
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isImporting)
        .accessibilityLabel("Import audio")
    }
}

struct CanvasRatioMenu: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        Menu {
            Button {
                EditorHaptics.tap()
                viewModel.setCanvasToSelectedClipOriginalRatio()
            } label: {
                Label("Original", systemImage: isOriginalSelected ? "checkmark" : "rectangle.ratio")
            }
            .disabled(!viewModel.canApplySelectedClipOriginalRatio)

            Divider()

            ForEach(CanvasRatioPreset.presets) { preset in
                Button {
                    EditorHaptics.tap()
                    viewModel.setCanvasPreset(preset)
                } label: {
                    Label(preset.title, systemImage: isSelected(preset) ? "checkmark" : "rectangle.ratio")
                }
            }
        } label: {
            CoreToolButtonContent(systemName: "aspectratio", title: "Ratio")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Canvas ratio")
    }

    private var isOriginalSelected: Bool {
        guard let clip = viewModel.selectedClip,
            clip.mediaType != .audio,
            let size = clip.source.naturalSize?.cgSize
        else { return false }
        let width = max(Int(abs(size.width).rounded()), 1)
        let height = max(Int(abs(size.height).rounded()), 1)
        return viewModel.project.renderSettings.width == width && viewModel.project.renderSettings.height == height
    }

    private func isSelected(_ preset: CanvasRatioPreset) -> Bool {
        viewModel.project.renderSettings.width == preset.width
            && viewModel.project.renderSettings.height == preset.height
    }
}

private struct CanvasColorMenu: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        Menu {
            ColorPicker(
                "Canvas Color",
                selection: Binding(
                    get: { viewModel.project.renderSettings.backgroundColor.swiftUIColor },
                    set: { viewModel.setCanvasBackgroundColor(RGBAColor($0)) }
                ),
                supportsOpacity: false
            )
            Button("Reset to Black") {
                viewModel.setCanvasBackgroundColor(.black)
            }
        } label: {
            CoreToolButtonContent(systemName: "paintpalette", title: "Canvas")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Canvas color")
    }
}
