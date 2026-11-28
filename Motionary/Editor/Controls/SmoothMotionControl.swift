import SwiftUI

struct SmoothMotionControl: View {
    @ObservedObject var viewModel: EditorViewModel
    let item: MediaTimelineItem
    let isEditable: Bool

    var body: some View {
        Menu {
            ForEach(SmoothMotionMode.allCases, id: \.self) { mode in
                Button {
                    EditorHaptics.tap()
                    viewModel.prepareSmoothMotion(for: item.id, mode: mode)
                } label: {
                    if item.usesSmoothMotion && item.smoothMotionMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
            if item.usesSmoothMotion {
                Divider()
                Button("Turn Off") {
                    EditorHaptics.tap()
                    viewModel.disableSmoothMotion(for: item.id)
                }
            }
        } label: {
            HStack(spacing: EditorWorkspaceControlStyle.horizontalSpacing) {
                Text("Smooth Motion")
                    .font(MotionaryDesign.Typography.controlTitleStrong)
                    .foregroundStyle(.primary)
                Spacer()
                Text(item.usesSmoothMotion ? item.smoothMotionMode.title : "Off")
                    .font(MotionaryDesign.Typography.pillLabel)
                    .foregroundStyle(item.usesSmoothMotion ? MotionaryTheme.accent : MotionaryTheme.textSecondary)
            }
            .padding(.horizontal, EditorWorkspaceControlStyle.horizontalPadding)
            .frame(maxWidth: .infinity)
            .frame(height: EditorWorkspaceControlStyle.height)
            .background(EditorWorkspaceControlStyle.backgroundColor(),
                in: RoundedRectangle(cornerRadius: EditorWorkspaceControlStyle.cornerRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEditable || viewModel.isPerformingLongTask)
        .accessibilityLabel("Smooth Motion")
        .accessibilityValue(item.usesSmoothMotion ? item.smoothMotionMode.title : "Off")
    }
}
