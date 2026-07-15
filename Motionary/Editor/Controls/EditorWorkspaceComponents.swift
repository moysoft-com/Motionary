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
                .padding(14)
                .opacity(isEnabled ? 1 : 0.42)
                .disabled(disablesContentWhenUnavailable && !isEnabled)
            }
        }
        .motionaryGlass(cornerRadius: 20)
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
                .font(.headline.weight(.semibold))
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
    var spacing: CGFloat = 12
    var padding: CGFloat = 12
    var backgroundOpacity = 0.05
    var cornerRadius: CGFloat = 15
    private let content: Content

    init(
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat = 12,
        padding: CGFloat = 12,
        backgroundOpacity: Double = 0.05,
        cornerRadius: CGFloat = 15,
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

struct EditorWorkspaceSelectionButton: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? MotionaryTheme.foregroundOnAccent : MotionaryTheme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                isSelected ? MotionaryTheme.accent : MotionaryTheme.surface,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
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
                .font(.caption.weight(.semibold))
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
                .frame(width: 42, height: 38)
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
