import Shimmer
import SwiftUI

private let loadingBand = Gradient(colors: [.clear, .black, .clear])

private struct MotionaryLoadingShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if !reduceMotion {
                Color.black.opacity(0.3)
                    .shimmering(gradient: loadingBand)
                    .mask(content)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct MotionaryProgressShimmer: ViewModifier {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        content.overlay {
            if !reduceMotion {
                GeometryReader { geometry in
                    Color.black.opacity(0.3)
                        .shimmering(gradient: loadingBand)
                        .mask(alignment: layoutDirection == .rightToLeft ? .trailing : .leading) {
                            Capsule()
                                .frame(width: geometry.size.width * min(max(progress, 0), 1), height: 4)
                        }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func motionaryLoadingShimmer() -> some View {
        modifier(MotionaryLoadingShimmer())
    }

    func motionaryProgressShimmer(_ progress: Double) -> some View {
        modifier(MotionaryProgressShimmer(progress: progress))
    }
}
