import SwiftUI

struct SuggestionStatusBadge: View {
    let status: SuggestionStatus

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor, in: .capsule)
    }

    private var foregroundColor: Color {
        switch status {
        case .normal: MotionaryTheme.textSecondary
        case .marked: .orange
        case .inProgress: MotionaryTheme.accent
        case .done: .green
        case .hidden: .secondary
        }
    }

    private var backgroundColor: Color {
        foregroundColor.opacity(0.14)
    }
}
