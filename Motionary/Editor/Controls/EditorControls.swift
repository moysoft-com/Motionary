// Editor toolbar and canvas-ratio controls.

import PhotosUI
import SwiftUI

struct CoreToolBar: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var selectedMediaItems: [PhotosPickerItem]
    @Binding var selectedAudioVideoItem: PhotosPickerItem?
    @Binding var isAudioFileImporterPresented: Bool
    @Binding var activePanel: CoreEditorPanel
    @Binding var propertyContextClipID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PhotosPicker(selection: $selectedMediaItems, matching: .any(of: [.images, .videos])) {
                    CoreToolButtonContent(systemName: "plus", title: "Media", isProminent: true)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isImporting)
                .accessibilityLabel("Import media")
                
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
                    systemName: "crop.rotate",
                    title: "Transform",
                    isSelected: activePanel == .transform,
                    isDisabled: viewModel.selectedClip == nil && propertyContextClipID == nil
                ) {
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
                    viewModel.splitSelectedClip()
                }

                CoreToolButton(
                    systemName: "trash",
                    title: "Delete",
                    isDisabled: viewModel.selectedClip == nil
                ) {
                    viewModel.deleteSelectedClip()
                }
                
                CoreToolButton(
                    systemName: "slider.horizontal.3",
                    title: "Adjust",
                    isSelected: activePanel == .adjust,
                    isDisabled: viewModel.selectedClip == nil && propertyContextClipID == nil
                ) {
                    if let selectedClipID = viewModel.selectedClipID {
                        propertyContextClipID = selectedClipID
                    }
                    activePanel = activePanel == .adjust ? .timeline : .adjust
                }

                CoreToolButton(
                    systemName: "sparkles.2",
                    title: "Effects",
                    isSelected: activePanel == .effects,
                    isDisabled: viewModel.selectedClip == nil && propertyContextClipID == nil
                ) {
                    if let selectedClipID = viewModel.selectedClipID {
                        propertyContextClipID = selectedClipID
                    }
                    activePanel = activePanel == .effects ? .timeline : .effects
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
            }
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .motionaryGlass(cornerRadius: 20)
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
