// Preview player surface and media-import empty state.

import PhotosUI
import SwiftUI
import UIKit

struct CorePreviewSection: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var selectedMediaItems: [PhotosPickerItem]
    @State private var posterImage: UIImage?

    init(viewModel: EditorViewModel, selectedMediaItems: Binding<[PhotosPickerItem]>) {
        self.viewModel = viewModel
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

                        if shouldShowOpeningPlaceholder {
                            openingPlaceholder
                        }

                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.deselectTimeline()
                            }

                        if let player = viewModel.player,
                            viewModel.previewContentRevision > 0 || !viewModel.isRenderingPreview
                        {
                            PreviewRendererView(player: player)
                                .frame(width: canvasRect.width, height: canvasRect.height)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: canvasRect.width, height: canvasRect.height)
                    .clipped()
                    .position(x: canvasRect.midX, y: canvasRect.midY)

                    PreviewTransformCanvas(
                        viewModel: viewModel,
                        canvasFrame: canvasRect
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)

                    Rectangle()
                        .stroke(.gray.opacity(0.3), lineWidth: 0.5)
                        .frame(width: canvasRect.width, height: canvasRect.height)
                        .position(x: canvasRect.midX, y: canvasRect.midY)
                        .allowsHitTesting(false)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .task(id: viewModel.projectID) {
            posterImage = await loadPosterImage()
        }
    }

    private var shouldShowOpeningPlaceholder: Bool {
        viewModel.previewContentRevision == 0
    }

    @ViewBuilder
    private var openingPlaceholder: some View {
        if let posterImage {
            Image(uiImage: posterImage)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [
                    MotionaryTheme.surfaceStrong,
                    MotionaryTheme.surfaceSubtle
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func loadPosterImage() async -> UIImage? {
        guard let url = viewModel.projectStore.existingPosterURL(for: viewModel.projectID) else {
            return nil
        }
        return await Task<UIImage?, Never>.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
    }
}
