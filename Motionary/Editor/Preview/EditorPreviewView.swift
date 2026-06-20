// Preview player surface and media-import empty state.

import PhotosUI
import SwiftUI

struct CorePreviewSection: View {
    @ObservedObject var viewModel: EditorViewModel
    @Binding var selectedMediaItems: [PhotosPickerItem]

    var body: some View {
        ZStack {
            if let player = viewModel.player {
                GeometryReader { geometry in
                    let ratio =
                        CGFloat(viewModel.project.renderSettings.width)
                        / CGFloat(max(viewModel.project.renderSettings.height, 1))
                    let canvasRect = aspectFitRect(in: geometry.size, aspectRatio: ratio)
                    let localCanvasRect = CGRect(origin: .zero, size: canvasRect.size)

                    ZStack {
                        viewModel.project.renderSettings.backgroundColor.swiftUIColor

                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.deselectTimeline()
                            }

                        PreviewRendererView(player: player)
                            .frame(width: canvasRect.width, height: canvasRect.height)
                            .allowsHitTesting(false)

                        PreviewTransformCanvas(
                            viewModel: viewModel,
                            canvasRect: localCanvasRect
                        )
                    }
                    .frame(width: canvasRect.width, height: canvasRect.height)
                    .border(.gray.opacity(0.3), width: 0.5)
                    .position(x: canvasRect.midX, y: canvasRect.midY)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            } else {
                ZStack {
                    viewModel.project.renderSettings.backgroundColor.swiftUIColor
                    VStack(spacing: 12) {
                        Image(systemName: "film")
                            .font(.system(size: 34, weight: .regular))
                            .foregroundStyle(MotionaryTheme.accent)
                        PhotosPicker(selection: $selectedMediaItems, matching: .any(of: [.images, .videos])) {
                            Label("Import Media", systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .foregroundStyle(Color.black)
                                .background(
                                    MotionaryTheme.accent,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if viewModel.isRenderingPreview {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .glassEffect(.regular)
            }
        }
    }
}
