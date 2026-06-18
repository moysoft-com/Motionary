// Shared visual tokens, glass surfaces, and inspector controls.

import SwiftUI

/// Stable visual tokens used throughout the application.
enum MotionaryTheme {
    static func background(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .light:
            return Color(red: 1 - 0.025, green: 1 - 0.027, blue: 1 - 0.032)
        case .dark:
            return Color(red: 0.025, green: 0.027, blue: 0.032)
        @unknown default:
            return .white
        }
    }
    static let textPrimary = Color.primary
    static let textSecondary = Color.primary.opacity(0.66)
    static let accent = Color(red: 0.44, green: 0.84, blue: 1)
    static let audio = Color(red: 0.64, green: 0.38, blue: 1)
    static let video = Color(red: 0.44, green: 0.84, blue: 1)
    static let selected = Color.primary
}

/// Applies Motionary's standard glass panel treatment to an arbitrary shape.
struct GlassPanelModifier<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .background {
                shape
                    .fill(Color.clear)
                    .glassEffect(.regular, in: shape)
            }
    }
}

extension View {
    /// Wraps a view in the standard rounded Motionary glass surface.
    func motionaryGlass(cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassPanelModifier(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }
}

/// Labeled inspector slider with an optional keyframe action.
struct InspectorSlider: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var isAnimated = false
    var hasKeyframeAtPlayhead = false
    var onKeyframe: (() -> Void)?
    var onOpenGraph: (() -> Void)?
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(MotionaryTheme.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(MotionaryTheme.textSecondary)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(MotionaryTheme.textPrimary)
                if let onKeyframe {
                    Button(action: onKeyframe) {
                        Image(systemName: hasKeyframeAtPlayhead ? "diamond.fill" : "diamond")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(hasKeyframeAtPlayhead ? MotionaryTheme.accent : MotionaryTheme.textSecondary)
                    .accessibilityLabel(
                        hasKeyframeAtPlayhead
                            ? "Remove \(title) keyframe"
                            : "Add \(title) keyframe"
                    )
                }
                if isAnimated, let onOpenGraph {
                    Button(action: onOpenGraph) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MotionaryTheme.accent)
                    .accessibilityLabel("Open \(title) graph")
                }
            }
            Slider(
                value: $value,
                in: range,
                step: step,
                onEditingChanged: onEditingChanged
            )
            .tint(MotionaryTheme.accent)
        }
    }
}
