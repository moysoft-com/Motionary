// Reusable editor design components built on the global Motionary tokens.

import SwiftUI

struct EditorWorkspaceSection<Content: View>: View {
    let title: String
    var systemImage: String?
    var spacing: CGFloat = MotionaryDesign.Spacing.md
    private let content: Content

    init(
        title: String,
        systemImage: String? = nil,
        spacing: CGFloat = MotionaryDesign.Spacing.md,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(MotionaryDesign.Typography.sectionTitle)

            content
        }
    }
}

struct EditorWorkspaceHorizontalStrip<Content: View>: View {
    var spacing: CGFloat = MotionaryDesign.Spacing.sm
    private let content: Content

    init(
        spacing: CGFloat = MotionaryDesign.Spacing.sm,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                content
            }
        }
    }
}

struct EditorWorkspacePillButton: View {
    let title: String
    var systemImage: String?
    let isSelected: Bool
    var isEnabled = true
    var indicatorColor: Color?
    var accessibilityValue: String?
    var haptic: () -> Void = { EditorHaptics.tap() }
    let action: () -> Void

    var body: some View {
        Button {
            haptic()
            action()
        } label: {
            HStack(spacing: MotionaryDesign.Spacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(MotionaryDesign.Typography.compactIcon)
                }

                Text(title)
                    .font(MotionaryDesign.Typography.pillLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if let indicatorColor {
                    Circle()
                        .fill(indicatorColor)
                        .frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(isSelected ? MotionaryTheme.foregroundOnAccent : MotionaryTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: MotionaryDesign.Control.compactHeight)
            .background(
                isSelected ? MotionaryTheme.accent : MotionaryTheme.surface,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue ?? (isSelected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct EditorWorkspaceTileButton<Icon: View>: View {
    let title: String
    let isSelected: Bool
    var isEnabled = true
    var accessibilityLabel: String?
    private let icon: Icon
    let action: () -> Void

    init(
        title: String,
        isSelected: Bool,
        isEnabled: Bool = true,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.accessibilityLabel = accessibilityLabel
        self.action = action
        self.icon = icon()
    }

    var body: some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            VStack(spacing: MotionaryDesign.Spacing.xs + 1) {
                icon
                    .font(MotionaryDesign.Typography.tileIcon)

                Text(title)
                    .font(MotionaryDesign.Typography.tileTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(isSelected ? MotionaryTheme.foregroundOnAccent : MotionaryTheme.textPrimary)
            .frame(
                width: MotionaryDesign.Control.tileSize.width,
                height: MotionaryDesign.Control.tileSize.height
            )
            .background(
                isSelected ? MotionaryTheme.accent : MotionaryTheme.surface,
                in: RoundedRectangle(cornerRadius: MotionaryDesign.Radius.tile, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension EditorWorkspaceTileButton where Icon == Image {
    init(
        title: String,
        systemImage: String,
        isSelected: Bool,
        isEnabled: Bool = true,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            isSelected: isSelected,
            isEnabled: isEnabled,
            accessibilityLabel: accessibilityLabel,
            action: action
        ) {
            Image(systemName: systemImage)
        }
    }
}

struct EditorWorkspaceCommandButton: View {
    let title: String
    let systemImage: String
    var role: ButtonRole?
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(role: role) {
            EditorHaptics.tap()
            action()
        } label: {
            EditorWorkspaceCommandLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

struct EditorWorkspaceCommandLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(MotionaryDesign.Typography.pillLabel)
            .frame(maxWidth: .infinity)
            .frame(height: MotionaryDesign.Control.compactHeight)
            .background(MotionaryTheme.surface, in: Capsule())
    }
}

struct EditorWorkspaceValueButton: View {
    let title: String
    let value: String
    var systemImage: String?
    var isEnabled = true
    var accessibilityHint: String?
    let action: () -> Void

    var body: some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            HStack(spacing: MotionaryDesign.Spacing.md) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(MotionaryDesign.Typography.compactIcon)
                        .foregroundStyle(MotionaryTheme.textSecondary)
                }

                Text(title)
                    .font(MotionaryDesign.Typography.controlTitle)

                Spacer()

                Text(value)
                    .font(MotionaryDesign.Typography.controlTitleStrong)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Image(systemName: "chevron.right")
                    .font(MotionaryDesign.Typography.compactIcon)
                    .foregroundStyle(MotionaryTheme.textSecondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, MotionaryDesign.Control.horizontalPadding)
            .frame(maxWidth: .infinity)
            .frame(height: MotionaryDesign.Control.height)
            .background(
                MotionaryDesign.Surface.control(),
                in: RoundedRectangle(cornerRadius: MotionaryDesign.Radius.control, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(accessibilityHint ?? "")
    }
}

struct EditorWorkspaceToggleButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var isEnabled = true
    var accessibilityLabel: String?
    var accessibilityValue: String?
    let action: () -> Void

    var body: some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            HStack(spacing: MotionaryDesign.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(MotionaryDesign.Typography.compactIcon)
                Text(title)
                    .font(MotionaryDesign.Typography.pillLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isSelected ? MotionaryTheme.foregroundOnAccent : MotionaryTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: MotionaryDesign.Control.toggleButtonHeight)
            .background(
                isSelected ? MotionaryTheme.accent : MotionaryTheme.surface,
                in: RoundedRectangle(cornerRadius: MotionaryDesign.Radius.button, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityValue(accessibilityValue ?? (isSelected ? "On" : "Off"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct EditorWorkspaceMirrorButtons: View {
    let isHorizontallyMirrored: Bool
    let isVerticallyMirrored: Bool
    var isEnabled = true
    let onHorizontalChange: (Bool) -> Void
    let onVerticalChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: MotionaryDesign.Spacing.sm) {
            EditorWorkspaceToggleButton(
                title: "Horizontal",
                systemImage: "arrow.left.and.right",
                isSelected: isHorizontallyMirrored,
                isEnabled: isEnabled,
                accessibilityLabel: "Mirror horizontally",
                accessibilityValue: isHorizontallyMirrored ? "Mirrored" : "Normal"
            ) {
                onHorizontalChange(!isHorizontallyMirrored)
            }

            EditorWorkspaceToggleButton(
                title: "Vertical",
                systemImage: "arrow.up.and.down",
                isSelected: isVerticallyMirrored,
                isEnabled: isEnabled,
                accessibilityLabel: "Mirror vertically",
                accessibilityValue: isVerticallyMirrored ? "Mirrored" : "Normal"
            ) {
                onVerticalChange(!isVerticallyMirrored)
            }
        }
    }
}
