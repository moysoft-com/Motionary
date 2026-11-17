// Preview player surface and media-import empty state.

import PhotosUI
import SwiftUI
import UIKit

struct CorePreviewSection: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var selectedMediaItems: [PhotosPickerItem]
    @Environment(\.displayScale) private var displayScale

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

                        if viewModel.player == nil && viewModel.previewContentRevision == 0 {
                            openingPlaceholder
                        }

                        PreviewRendererView(playerLayer: viewModel.livePreviewPresentation.playerLayer)
                            .frame(width: canvasRect.width, height: canvasRect.height)
                            .allowsHitTesting(false)

                        LivePreviewSurface(presentation: viewModel.livePreviewPresentation)
                            .frame(width: canvasRect.width, height: canvasRect.height)

                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.deselectTimeline()
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
                .onChange(of: canvasRect, initial: true) { _, rect in
                    viewModel.setPreviewDisplayPixelSize(
                        CGSize(
                            width: rect.width * max(displayScale, 1),
                            height: rect.height * max(displayScale, 1)
                        ))
                }
            }
        }
        .task(id: viewModel.projectID) {
            posterImage = await loadPosterImage()
        }
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
