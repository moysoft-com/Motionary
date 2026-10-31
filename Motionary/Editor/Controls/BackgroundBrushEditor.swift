import AVFoundation
import CoreImage
import ImageIO
import SwiftUI

struct BackgroundBrushSession: Identifiable {
    let id: UUID
    let url: URL
    let sourceTime: Double
    let settings: BackgroundRemovalSettings
}

struct BackgroundBrushEditor: View {
    let session: BackgroundBrushSession
    let onApply: ([BackgroundBrushStroke]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var strokes: [BackgroundBrushStroke]
    @State private var redoStrokes: [BackgroundBrushStroke] = []
    @State private var activePoints: [BackgroundBrushPoint] = []
    @State private var diameter = 0.08
    @State private var restores = false
    @State private var showsOriginal = false
    @State private var source: UIImage?
    @State private var preview: UIImage?
    @State private var error: String?

    init(session: BackgroundBrushSession, onApply: @escaping ([BackgroundBrushStroke]) -> Void) {
        self.session = session
        self.onApply = onApply
        _strokes = State(initialValue: session.settings.strokes)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Group {
                    if let source {
                        canvas(source)
                    } else if let error {
                        ContentUnavailableView("Cannot open media", systemImage: "photo.badge.exclamationmark",
                            description: Text(error))
                    } else {
                        ProgressView("Loading source…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
                EditorWorkspaceCard(spacing: 16) {
                    HStack(spacing: 10) {
                        EditorWorkspaceSelectionButton(title: "Erase", systemImage: "eraser",
                            isSelected: !restores) { restores = false }
                        EditorWorkspaceSelectionButton(title: "Restore", systemImage: "paintbrush.pointed",
                            isSelected: restores) { restores = true }
                    }
                    EditorValueScrubber(title: "Brush size", systemImage: "circle",
                        value: diameter, range: 0.01...0.4, step: 0.01,
                        format: { "\(Int(($0 * 100).rounded()))%" },
                        onBegan: {}, onChanged: { diameter = $0 }, onEnded: {})
                    HStack(spacing: 22) {
                        EditorWorkspaceIconButton(systemName: "arrow.uturn.backward", accessibilityLabel: "Undo stroke",
                            isEnabled: !strokes.isEmpty) {
                            if let stroke = strokes.popLast() { redoStrokes.append(stroke) }
                        }
                        EditorWorkspaceIconButton(systemName: "arrow.uturn.forward", accessibilityLabel: "Redo stroke",
                            isEnabled: !redoStrokes.isEmpty) {
                            if let stroke = redoStrokes.popLast() { strokes.append(stroke) }
                        }
                        Spacer()
                        Toggle("Original", isOn: $showsOriginal)
                            .font(MotionaryDesign.Typography.pillLabel)
                            .fixedSize()
                            .tint(MotionaryTheme.accent)
                    }
                    Button("Reset cutout", role: .destructive) {
                        strokes = []
                        redoStrokes = []
                    }
                    .disabled(strokes.isEmpty)
                    .font(MotionaryDesign.Typography.pillLabel)
                }
                .disabled(source == nil)
                Text("Erase the background. Restore brings back the original pixels.")
                    .font(.caption)
                    .foregroundStyle(MotionaryTheme.textSecondary)
            }
            .padding(20)
            .background(MotionaryTheme.background(for: colorScheme))
            .navigationTitle("Custom removal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onApply(strokes); dismiss() }
                        .disabled(source == nil)
                }
            }
            .task {
                do { source = try await Self.loadSource(session) }
                catch { self.error = error.localizedDescription }
            }
            .task(id: PreviewKey(loaded: source != nil, strokes: strokes)) {
                guard let source else { return }
                var settings = session.settings
                settings.strokes = strokes
                let task = Task.detached(priority: .userInitiated) {
                    guard let cgImage = source.cgImage else { return source }
                    let input = CIImage(cgImage: cgImage)
                    let output = BackgroundRemovalImageRenderer.apply(settings, matte: nil, to: input)
                    guard let result = CIContext().createCGImage(output, from: input.extent) else { return source }
                    return UIImage(cgImage: result)
                }
                let result = await task.value
                guard !Task.isCancelled else { return }
                preview = result
            }
        }
    }

    private struct PreviewKey: Equatable {
        let loaded: Bool
        let strokes: [BackgroundBrushStroke]
    }

    private func canvas(_ source: UIImage) -> some View {
        GeometryReader { geometry in
            let ratio = source.size.width / max(source.size.height, 1)
            let width = min(geometry.size.width, geometry.size.height * ratio)
            let size = CGSize(width: width, height: width / ratio)
            ZStack {
                Canvas { context, bounds in
                    let side: CGFloat = 14
                    for y in 0...Int(bounds.height / side) {
                        for x in 0...Int(bounds.width / side) {
                            context.fill(Path(CGRect(x: CGFloat(x) * side, y: CGFloat(y) * side, width: side, height: side)),
                                with: .color(.white.opacity((x + y).isMultiple(of: 2) ? 0.08 : 0.16)))
                        }
                    }
                }
                Image(uiImage: showsOriginal ? source : (preview ?? source))
                    .resizable().scaledToFit()
                Canvas { context, bounds in
                    guard let first = activePoints.first else { return }
                    var path = Path()
                    path.move(to: CGPoint(x: first.x * bounds.width, y: first.y * bounds.height))
                    for point in activePoints.dropFirst() {
                        path.addLine(to: CGPoint(x: point.x * bounds.width, y: point.y * bounds.height))
                    }
                    let brushWidth = diameter * min(bounds.width, bounds.height)
                    let color = restores ? Color.green : Color.red
                    context.stroke(path, with: .color(color.opacity(0.6)),
                        style: StrokeStyle(lineWidth: brushWidth, lineCap: .round, lineJoin: .round))
                    if let last = activePoints.last {
                        context.stroke(Path(ellipseIn: CGRect(x: last.x * bounds.width - brushWidth / 2,
                            y: last.y * bounds.height - brushWidth / 2, width: brushWidth, height: brushWidth)),
                            with: .color(.white), lineWidth: 1)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    activePoints.append(BackgroundBrushPoint(
                        x: min(max(value.location.x / max(size.width, 1), 0), 1),
                        y: min(max(value.location.y / max(size.height, 1), 0), 1)))
                }
                .onEnded { _ in
                    guard !activePoints.isEmpty else { return }
                    strokes.append(BackgroundBrushStroke(points: activePoints, diameter: diameter, restores: restores))
                    activePoints = []
                    redoStrokes = []
                })
            .accessibilityLabel("Cutout canvas. Draw to \(restores ? "restore" : "erase") areas.")
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }

    private static func loadSource(_ session: BackgroundBrushSession) async throws -> UIImage {
        let task = Task.detached(priority: .userInitiated) {
            if let source = CGImageSourceCreateWithURL(session.url as CFURL, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600,
                ] as CFDictionary) { return UIImage(cgImage: image) }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: session.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1600, height: 1600)
            let result = try await generator.image(at: CMTime(seconds: session.sourceTime, preferredTimescale: 600))
            return UIImage(cgImage: result.image)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
