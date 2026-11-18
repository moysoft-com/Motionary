import SwiftUI

struct MotionaryProjectLoadingView: View {
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(MotionaryTheme.accent)
                .motionaryLoadingShimmer()
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MotionaryTheme.textPrimary)
                .motionaryLoadingShimmer()
        }
        .padding(18)
        .motionaryGlass(cornerRadius: 18)
    }
}
