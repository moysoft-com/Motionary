// Editor-wide busy-state presentation, formatting, geometry helpers, and haptics.

import SwiftUI
import UIKit

struct EditorBusyOverlay: View {
    @ObservedObject private var viewModel: EditorViewModel
    @ObservedObject private var exportState: ExportState
    @ObservedObject private var previewState: PreviewState
    let onCancelRequest: (CGPoint) -> Void
    @State private var showsOverlay = false

    init(viewModel: EditorViewModel, onCancelRequest: @escaping (CGPoint) -> Void) {
        self.viewModel = viewModel
        _exportState = ObservedObject(wrappedValue: viewModel.exportState)
        _previewState = ObservedObject(wrappedValue: viewModel.previewState)
        self.onCancelRequest = onCancelRequest
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if showsOverlay, let title = viewModel.longRunningTaskTitle {
                    ZStack {
                        Color.black.opacity(0.62)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onEnded { value in
                                        onCancelRequest(value.location)
                                    }
                            )

                        VStack(spacing: 12) {
                            if exportState.isExporting {
                                ProgressView(value: exportState.progress)
                                    .motionaryProgressShimmer(exportState.progress)
                            } else if let analysisState = viewModel.analysisState {
                                ProgressView(value: analysisState.progress)
                                    .motionaryProgressShimmer(analysisState.progress)
                            } else if let progress = viewModel.depthPreparationProgress, !viewModel.depthPreparationIndeterminate {
                                ProgressView(value: progress)
                                    .motionaryProgressShimmer(progress)
                            } else {
                                ProgressView()
                                    .motionaryLoadingShimmer()
                            }
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(MotionaryTheme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                                .motionaryLoadingShimmer()
                            Text("Tap outside to stop")
                                .font(.caption)
                                .foregroundStyle(MotionaryTheme.textSecondary)
                        }
                        .tint(MotionaryTheme.accent)
                        .padding(18)
                        .frame(
                            width: min(max(geometry.size.width * 0.72, 236), 330)
                        )
                        .motionaryGlass(cornerRadius: 18)
                    }
                    .zIndex(1_000)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: DepthBakeStore.preparationProgress)
            .receive(on: DispatchQueue.main)) { notification in
            viewModel.handleDepthPreparationProgress(notification)
        }
        .task(id: busyKey) {
            showsOverlay = false
            guard viewModel.shouldPresentBusyOverlay else { return }
            try? await Task.sleep(nanoseconds: overlayDelay)
            guard !Task.isCancelled, viewModel.shouldPresentBusyOverlay else { return }
            showsOverlay = true
        }
    }

    private var busyKey: String {
        if viewModel.depthPreparationProgress != nil { return "depth" }
        if exportState.isExporting { return "export" }
        if viewModel.isImporting { return "import" }
        if let kind = viewModel.analysisState?.kind { return kind.rawValue }
        if viewModel.isInitialPreviewLoadBlocking { return "preview" }
        return "idle"
    }

    private var overlayDelay: UInt64 {
        viewModel.isInitialPreviewLoadBlocking ? 180_000_000 : 650_000_000
    }
}

struct EditorCancelTaskPopover: View {
    let title: String
    let message: String
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(MotionaryTheme.textPrimary)
            Text(message)
                .font(.caption)
                .foregroundStyle(MotionaryTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Keep Waiting", action: onDismiss)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MotionaryTheme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(MotionaryTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .buttonStyle(.plain)

                Button("Stop Task", role: .destructive, action: onConfirm)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 244)
        .motionaryGlass(cornerRadius: 18)
        .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
    }
}

struct MotionaryConfirmationToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(MotionaryTheme.accent)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MotionaryTheme.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .motionaryGlass(cornerRadius: 17)
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
    }
}

func formatClock(_ value: Double) -> String {
    let seconds = max(Int(value.rounded(.down)), 0)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

func aspectFitRect(in size: CGSize, aspectRatio: CGFloat) -> CGRect {
    guard size.width > 0, size.height > 0, aspectRatio > 0 else {
        return CGRect(origin: .zero, size: size)
    }

    let containerRatio = size.width / size.height
    let fittedSize: CGSize
    if containerRatio > aspectRatio {
        let height = size.height
        fittedSize = CGSize(width: height * aspectRatio, height: height)
    } else {
        let width = size.width
        fittedSize = CGSize(width: width, height: width / aspectRatio)
    }

    return CGRect(
        x: (size.width - fittedSize.width) * 0.5,
        y: (size.height - fittedSize.height) * 0.5,
        width: fittedSize.width,
        height: fittedSize.height
    )
}

@MainActor
func timelineDragHaptic() {
    EditorHaptics.dragStart()
}

@MainActor
enum EditorHaptics {
    // Generator teardown touches UIKit's shared feedback preferences. Keep
    // generators alive instead of allocating/deallocating one per scrub tick.
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()
    private static var lastSelectionTime: CFTimeInterval = -.infinity

    static func tap() { light.impactOccurred(intensity: 0.55) }

    static func selection() {
        let now = CACurrentMediaTime()
        guard now - lastSelectionTime >= 1.0 / 30.0 else { return }
        lastSelectionTime = now
        selectionGenerator.selectionChanged()
    }

    static func dragStart() { medium.impactOccurred(intensity: 0.85) }
    static func trimStart() { light.impactOccurred(intensity: 0.75) }
    static func scrubStart() {
        lastSelectionTime = CACurrentMediaTime()
        selectionGenerator.prepare()
        selectionGenerator.selectionChanged()
    }
    static func snap() { rigid.impactOccurred(intensity: 0.9) }
    static func layerReady() { medium.impactOccurred(intensity: 0.82) }
    static func editCommit() { soft.impactOccurred(intensity: 0.65) }
    static func deletePrompt() { notification.notificationOccurred(.warning) }
    static func deleteCommit() { notification.notificationOccurred(.success) }
}
