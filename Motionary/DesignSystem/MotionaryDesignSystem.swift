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
    static let surfaceSubtle = Color.primary.opacity(0.055)
    static let surface = Color.primary.opacity(0.08)
    static let surfaceStrong = Color.primary.opacity(0.14)
    static let separator = Color.primary.opacity(0.1)
    static let control = Color.primary
    static let accent = Color(red: 0.44, green: 0.84, blue: 1)
    static let foregroundOnAccent = Color.black
    static let audio = Color(red: 0.64, green: 0.38, blue: 1)
    static let video = Color(red: 0.44, green: 0.84, blue: 1)
    static let selected = Color.primary
}

/// Layout, typography, and shape tokens for Motionary UI components.
enum MotionaryDesign {
    enum Spacing {
        static let xxs: CGFloat = 3
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 10
        static let lg: CGFloat = 12
        static let xl: CGFloat = 14
        static let xxl: CGFloat = 18
    }

    enum Radius {
        static let control: CGFloat = 10
        static let button: CGFloat = 12
        static let tile: CGFloat = 12
        static let compactPanel: CGFloat = 13
        static let graph: CGFloat = 14
        static let card: CGFloat = 15
        static let panel: CGFloat = 20
    }

    enum Control {
        static let height: CGFloat = 36
        static let compactHeight: CGFloat = 38
        static let toggleButtonHeight: CGFloat = 44
        static let rangeStripHeight: CGFloat = 44
        static let iconButtonSize = CGSize(width: 42, height: 38)
        static let tileSize = CGSize(width: 82, height: 58)
        static let toolButtonSize = CGSize(width: 62, height: 54)
        static let scrubberLabelWidth: CGFloat = 82
        static let scrubberValueWidth: CGFloat = 54
        static let scrubberTickSpacing: CGFloat = 8
        static let rangeHandleSize = CGSize(width: 18, height: 28)
        static let rangeHandleHitSize = CGSize(width: 44, height: 44)
        static let horizontalPadding: CGFloat = 10
        static let horizontalSpacing: CGFloat = 8
    }

    enum Typography {
        static let workspaceHeader = Font.headline.weight(.semibold)
        static let sectionTitle = Font.callout.weight(.medium)
        static let controlTitle = Font.callout.weight(.medium)
        static let controlTitleStrong = Font.callout.weight(.semibold)
        static let controlValue = Font.caption.monospacedDigit().weight(.semibold)
        static let pillLabel = Font.caption.weight(.semibold)
        static let tileTitle = Font.caption2.weight(.semibold)
        static let tileIcon = Font.system(size: 17, weight: .semibold)
        static let compactIcon = Font.caption.weight(.semibold)
        static let borderedIcon = Font.system(size: 16, weight: .semibold)
        static let statusLabel = Font.caption.weight(.semibold)
        static let rangeHandle = Font.caption2.weight(.bold)
        static let metricTitle = Font.caption2.weight(.semibold)
        static let metricValue = Font.caption.monospacedDigit().weight(.bold)
    }

    enum Surface {
        static func control(isActive: Bool = false) -> Color {
            Color.primary.opacity(isActive ? 0.085 : 0.045)
        }
    }
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

/// A reusable Motionary-styled decimal number pad presented from any label.
struct MotionaryNumberPadPopover<Label: View>: View {
    @Binding private var isPresented: Bool
    private let onValueChange: (Double) -> Void
    private let label: () -> Label

    @State private var input = ""

    init(
        isPresented: Binding<Bool>,
        onValueChange: @escaping (Double) -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        _isPresented = isPresented
        self.onValueChange = onValueChange
        self.label = label
    }

    var body: some View {
        Button {
            input = ""
            isPresented = true
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            numberPad
                .presentationCompactAdaptation(.popover)
                .presentationBackground(.clear)
        }
    }

    private var numberPad: some View {
        VStack(spacing: 10) {
            Text(input.isEmpty ? "0" : input)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(input.isEmpty ? MotionaryTheme.textSecondary : MotionaryTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 4)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9"], id: \.self) { digit in
                    key(digit) { append(digit) }
                }

                key(decimalSeparator) { appendDecimalSeparator() }
                key("0") { append("0") }
                key(systemName: "delete.left") { deleteLast() }
            }

            Button("Done") {
                isPresented = false
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(MotionaryTheme.foregroundOnAccent)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(MotionaryTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .buttonStyle(.plain)
        }
        .padding(MotionaryDesign.Spacing.xl)
        .frame(width: 224)
        .motionaryGlass(cornerRadius: MotionaryDesign.Radius.panel)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    }

    private var decimalSeparator: String {
        Locale.current.decimalSeparator ?? ","
    }

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title3.monospacedDigit().weight(.medium))
                .foregroundStyle(MotionaryTheme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    MotionaryTheme.surface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private func key(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(MotionaryTheme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    MotionaryTheme.surface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete")
    }

    private func append(_ digit: String) {
        input.append(digit)
        publishValue()
    }

    private func appendDecimalSeparator() {
        guard !input.contains(decimalSeparator) else { return }
        if input.isEmpty { input = "0" }
        input.append(decimalSeparator)
    }

    private func deleteLast() {
        guard !input.isEmpty else { return }
        input.removeLast()
        publishValue()
    }

    private func publishValue() {
        let normalized = input.replacingOccurrences(of: decimalSeparator, with: ".")
        guard let value = Double(normalized), value.isFinite else { return }
        onValueChange(value)
    }
}
