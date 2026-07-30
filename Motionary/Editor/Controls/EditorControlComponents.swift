// Reusable editor toolbar buttons, readouts, and command controls.

import SwiftUI

struct CoreToolButton: View {
    let systemName: String
    let title: String
    var isSelected = false
    var isDisabled = false
    var action: () -> Void

    var body: some View {
        Button {
            EditorHaptics.tap()
            action()
        } label: {
            CoreToolButtonContent(systemName: systemName, title: title, isProminent: isSelected)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
        .accessibilityLabel(title)
    }
}

struct CoreToolButtonContent: View {
    let systemName: String
    let title: String
    var isProminent = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemName)
                .font(MotionaryDesign.Typography.tileIcon)
            Text(title)
                .font(MotionaryDesign.Typography.tileTitle)
                .lineLimit(1)
        }
        .foregroundStyle(isProminent ? MotionaryTheme.foregroundOnAccent : MotionaryTheme.textPrimary)
        .frame(
            width: MotionaryDesign.Control.toolButtonSize.width,
            height: MotionaryDesign.Control.toolButtonSize.height
        )
        .background {
            RoundedRectangle(cornerRadius: MotionaryDesign.Radius.button, style: .continuous)
                .fill(isProminent ? MotionaryTheme.accent : MotionaryTheme.surface)
        }
    }
}

struct CompactIconButton: View {
    let systemName: String
    let title: String
    var isProminent = false
    var isDisabled = false
    var action: () -> Void
    var isBordered = true
    var tintsProminentIcon = false

    var body: some View {
        ZStack {
            Button {
                EditorHaptics.tap()
                action()
            } label: {
                Image(systemName: systemName)
                    .font(.system(size: isBordered ? 16 : 18, weight: .semibold))
                    .frame(width: isBordered ? 40 : 18, height: isBordered ? 36 : 18)
                    .foregroundStyle(
                        isBordered
                            ? Color.clear
                            : (isProminent && tintsProminentIcon ? MotionaryTheme.accent : Color.primary)
                    )
                    .background {
                        if isBordered {
                            RoundedRectangle(
                                cornerRadius: MotionaryDesign.Radius.button + 1,
                                style: .continuous
                            )
                                .fill(isProminent ? MotionaryTheme.accent : MotionaryTheme.surface)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel(title)
            if isBordered {
                Image(systemName: systemName)
                    .font(MotionaryDesign.Typography.borderedIcon)
                    .frame(width: 40, height: 36)
                    .foregroundStyle(isProminent ? MotionaryTheme.foregroundOnAccent : MotionaryTheme.textPrimary)
            }
        }
    }
}
