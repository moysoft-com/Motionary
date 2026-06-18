// Editor-wide busy-state presentation, formatting, geometry helpers, and haptics.

import SwiftUI
import UIKit

struct EditorBusyOverlay: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        if viewModel.isImporting || viewModel.isExporting {
            VStack(spacing: 12) {
                ProgressView(value: viewModel.isExporting ? viewModel.exportProgress : nil)
                    .tint(MotionaryTheme.accent)
                Text(viewModel.isExporting ? "Exporting \(Int(viewModel.exportProgress * 100))%" : "Importing")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MotionaryTheme.textPrimary)
            }
            .padding(18)
            .motionaryGlass(cornerRadius: 18)
        }
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

func timelineDragHaptic() {
    EditorHaptics.dragStart()
}

enum EditorHaptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.55)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func dragStart() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.85)
    }

    static func trimStart() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.75)
    }

    static func scrubStart() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func snap() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.9)
    }

    static func layerReady() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.82)
    }

    static func editCommit() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.65)
    }

    static func deletePrompt() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func deleteCommit() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
