import SwiftUI

enum MotionaryTheme {
    static func background(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .light:
            return Color(red: 1-0.025, green: 1-0.027, blue: 1-0.032)
        case .dark:
            return Color(red: 0.025, green: 0.027, blue: 0.032)
        @unknown default:
            return .white
        }
    }
    static let surface = Color.primary.opacity(0.07)
    static let surfaceStrong = Color.primary.opacity(0.12)
    static let textPrimary = Color.primary
    static let textSecondary = Color.primary.opacity(0.66)
    static let accent = Color(red: 0.44, green: 0.84, blue: 1)
    static let accentWarm = Color(red: 1, green: 0.56, blue: 0.32)
    static let audio = Color(red: 0.64, green: 0.38, blue: 1)
    static let video = Color(red: 0.44, green: 0.84, blue: 1)
    static let selected = Color.primary
}

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
    func motionaryGlass(cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassPanelModifier(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }
}

struct IconButton: View {
    let systemName: String
    let title: String
    var isProminent = false
    var isDisabled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 36)
                .foregroundStyle(isProminent ? Color.black : MotionaryTheme.textPrimary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isProminent ? MotionaryTheme.accent : Color.white.opacity(0.08))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .opacity(isDisabled ? 0.35 : 1)
        .disabled(isDisabled)
        .accessibilityLabel(title)
        .help(title)
    }
}

struct InspectorSlider: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var onKeyframe: (() -> Void)?

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
                        Image(systemName: "diamond")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MotionaryTheme.accent)
                    .accessibilityLabel("Add \(title) keyframe")
                }
            }
            Slider(value: $value, in: range, step: step)
                .tint(MotionaryTheme.accent)
        }
    }
}
