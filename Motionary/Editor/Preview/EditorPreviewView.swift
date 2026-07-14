// Preview player surface and media-import empty state.

import PhotosUI
import SwiftUI

struct CorePreviewSection: View {
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject private var previewState: PreviewState
    @Binding var selectedMediaItems: [PhotosPickerItem]

    init(viewModel: EditorViewModel, selectedMediaItems: Binding<[PhotosPickerItem]>) {
        self.viewModel = viewModel
        _previewState = ObservedObject(wrappedValue: viewModel.previewState)
        _selectedMediaItems = selectedMediaItems
    }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let ratio =
                    CGFloat(viewModel.project.renderSettings.width)
                    / CGFloat(max(viewModel.project.renderSettings.height, 1))
                let canvasRect = aspectFitRect(in: geometry.size, aspectRatio: ratio)

                ZStack {
                    ZStack {
                        viewModel.project.renderSettings.backgroundColor.swiftUIColor

                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.deselectTimeline()
                            }

                        if let player = viewModel.player {
                            PreviewRendererView(player: player)
                                .frame(width: canvasRect.width, height: canvasRect.height)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: canvasRect.width, height: canvasRect.height)
                    .clipped()
                    .border(.gray.opacity(0.3), width: 0.5)
                    .position(x: canvasRect.midX, y: canvasRect.midY)

                    PreviewTransformCanvas(
                        viewModel: viewModel,
                        canvasFrame: canvasRect
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }

            if previewState.isBuilding, viewModel.player == nil {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .glassEffect(.regular)
            }
        }
    }
}
