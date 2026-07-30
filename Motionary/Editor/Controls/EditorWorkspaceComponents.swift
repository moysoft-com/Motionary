// Reusable layout and control primitives shared by all editor workspaces.

import SwiftUI

struct EditorWorkspaceEmptyState {
    let title: String
    let systemImage: String
}

enum EditorWorkspaceContentStyle {
    case fixed
    case scrollable
}

struct EditorWorkspaceShell<Accessory: View, Content: View>: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let emptyState: EditorWorkspaceEmptyState?
    let contentStyle: EditorWorkspaceContentStyle
    let disablesContentWhenUnavailable: Bool
    private let accessory: Accessory
    private let content: Content

    init(
        title: String,
        systemImage: String,
        isEnabled: Bool = true,
        emptyState: EditorWorkspaceEmptyState? = nil,
        contentStyle: EditorWorkspaceContentStyle = .scrollable,
        disablesContentWhenUnavailable: Bool = false,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.emptyState = emptyState
        self.contentStyle = contentStyle
        self.disablesContentWhenUnavailable = disablesContentWhenUnavailable
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        ZStack {
            if let emptyState {
                EditorWorkspaceMessage(
                    text: emptyState.title,
                    systemImage: emptyState.systemImage,
                    prominence: .emptyState
                )
            } else {
                VStack(spacing: 10) {
                    EditorWorkspaceHeader(
                        title: title,
                        systemImage: systemImage,
                        accessory: { accessory }
                    )

                    Group {
                        switch contentStyle {
                        case .fixed:
                            content
                        case .scrollable:
                            ScrollView {
                                content
                                    .padding(.bottom, 6)
                            }
                            .scrollIndicators(.hidden)
                            .scrollDismissesKeyboard(.interactively)
                        }
                    }
                }
                .padding(MotionaryDesign.Spacing.xl)
                .opacity(isEnabled ? 1 : 0.42)
                .disabled(disablesContentWhenUnavailable && !isEnabled)
            }
        }
        .motionaryGlass(cornerRadius: MotionaryDesign.Radius.panel)
    }
}

extension EditorWorkspaceShell where Accessory == EmptyView {
    init(
        title: String,
        systemImage: String,
        isEnabled: Bool = true,
        emptyState: EditorWorkspaceEmptyState? = nil,
        contentStyle: EditorWorkspaceContentStyle = .scrollable,
        disablesContentWhenUnavailable: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            isEnabled: isEnabled,
            emptyState: emptyState,
            contentStyle: contentStyle,
            disablesContentWhenUnavailable: disablesContentWhenUnavailable,
            accessory: { EmptyView() },
            content: content
        )
    }
}

struct EditorWorkspaceHeader<Accessory: View>: View {
    let title: String
    let systemImage: String
    private let accessory: Accessory

    init(
        title: String,
        systemImage: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(MotionaryDesign.Typography.workspaceHeader)
                .labelStyle(.titleAndIcon)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            accessory
        }
        .frame(height: 22)
    }
}

extension EditorWorkspaceHeader where Accessory == EmptyView {
    init(title: String, systemImage: String) {
        self.init(title: title, systemImage: systemImage, accessory: { EmptyView() })
    }
}

struct EditorWorkspaceCard<Content: View>: View {
    var alignment: HorizontalAlignment = .center
    var spacing: CGFloat = MotionaryDesign.Spacing.lg
    var padding: CGFloat = MotionaryDesign.Spacing.lg
    var backgroundOpacity = 0.05
    var cornerRadius: CGFloat = MotionaryDesign.Radius.card
    private let content: Content

    init(
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat = MotionaryDesign.Spacing.lg,
        padding: CGFloat = MotionaryDesign.Spacing.lg,
        backgroundOpacity: Double = 0.05,
        cornerRadius: CGFloat = MotionaryDesign.Radius.card,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.padding = padding
        self.backgroundOpacity = backgroundOpacity
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        VStack(alignment: alignment, spacing: spacing) {
            content
        }
        .padding(padding)
        .background(
            Color.primary.opacity(backgroundOpacity),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

struct EditorWorkspaceColorRow: View {
    let title: String
    let color: Color
    var systemImage: String?
    var supportsOpacity = true
    var spacing: CGFloat = 8
    var titleWeight: Font.Weight = .medium
    let onChange: (Color) -> Void

    var body: some View {
        HStack(spacing: spacing) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.callout.weight(titleWeight))
            Spacer()
            ColorPicker(
                title,
                selection: Binding(get: { color }, set: onChange),
                supportsOpacity: supportsOpacity
            )
            .labelsHidden()
        }
    }
}

enum EditorWorkspaceControlStyle {
    static let height = MotionaryDesign.Control.height
    static let cornerRadius = MotionaryDesign.Radius.control
    static let horizontalSpacing = MotionaryDesign.Control.horizontalSpacing
    static let horizontalPadding = MotionaryDesign.Control.horizontalPadding

    static func backgroundColor(isActive: Bool = false) -> Color {
        MotionaryDesign.Surface.control(isActive: isActive)
    }
}

struct EditorWorkspaceOnOffControl<Accessory: View>: View {
    let title: String
    let isOn: Bool
    var isEnabled = true
    let onChange: (Bool) -> Void
    private let accessory: Accessory

    init(
        title: String,
        isOn: Bool,
        isEnabled: Bool = true,
        onChange: @escaping (Bool) -> Void,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.onChange = onChange
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: EditorWorkspaceControlStyle.horizontalSpacing) {
            Button {
                onChange(!isOn)
                EditorHaptics.tap()
            } label: {
                HStack(spacing: EditorWorkspaceControlStyle.horizontalSpacing) {
                    Text(title)
                        .font(MotionaryDesign.Typography.controlTitleStrong)

                    Spacer()

                    Text(isOn ? "On" : "Off")
                        .font(MotionaryDesign.Typography.pillLabel)
                        .foregroundStyle(isOn ? MotionaryTheme.accent : MotionaryTheme.textSecondary)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "On" : "Off")

            accessory
        }
        .padding(.horizontal, EditorWorkspaceControlStyle.horizontalPadding)
        .frame(maxWidth: .infinity)
        .frame(height: EditorWorkspaceControlStyle.height)
        .background(
            EditorWorkspaceControlStyle.backgroundColor(),
            in: RoundedRectangle(
                cornerRadius: EditorWorkspaceControlStyle.cornerRadius,
                style: .continuous
            )
        )
    }
}

extension EditorWorkspaceOnOffControl where Accessory == EmptyView {
    init(
        title: String,
        isOn: Bool,
        isEnabled: Bool = true,
        onChange: @escaping (Bool) -> Void
    ) {
        self.init(
            title: title,
            isOn: isOn,
            isEnabled: isEnabled,
            onChange: onChange,
            accessory: { EmptyView() }
        )
    }
}

struct EditorWorkspaceSelectionButton: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        EditorWorkspacePillButton(
            title: title,
            systemImage: systemImage,
            isSelected: isSelected,
            isEnabled: isEnabled,
            action: action
        )
    }
}

struct EditorWorkspaceIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var isEnabled = true
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(MotionaryDesign.Typography.compactIcon)
                .frame(width: 25, height: 25)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.3)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct EditorWorkspaceCapsuleIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(
                    width: MotionaryDesign.Control.iconButtonSize.width,
                    height: MotionaryDesign.Control.iconButtonSize.height
                )
                .background(MotionaryTheme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct EditorWorkspaceMessage: View {
    enum Prominence {
        case informational
        case emptyState
    }

    let text: String
    let systemImage: String
    var prominence: Prominence = .informational

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(prominence == .emptyState ? .subheadline.weight(.semibold) : .caption)
            .foregroundStyle(MotionaryTheme.textSecondary)
            .frame(
                maxWidth: .infinity,
                maxHeight: prominence == .emptyState ? .infinity : nil,
                alignment: prominence == .emptyState ? .center : .leading
            )
    }
}
