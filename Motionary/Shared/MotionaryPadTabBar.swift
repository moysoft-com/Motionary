// Floating iPad tab bar backed by the native segmented selection control.

import SwiftUI
import UIKit

/// Root destinations reachable from the iPad tab bar.
enum MotionaryPadTab: Int, CaseIterable {
    case home
    case settings

    var title: String {
        switch self {
        case .home: return "Motionary"
        case .settings: return "Settings"
        }
    }
}

/// Liquid Glass tab bar with a native selection control on iPad.
struct MotionaryPadTabBar: View {
    @Binding var selection: Int
    let isSearchEnabled: Bool
    let isSearching: Bool
    let onSearch: () -> Void

    @State private var bottomSafeArea: CGFloat = MotionaryPadTabBarMetrics.defaultBottomSafeArea
    @State private var keyboardOverlap: CGFloat = 0
    @State private var keyboardAnimationDuration: Double = MotionaryPadTabBarMetrics.defaultKeyboardDuration

    /// Reserves the same space in the content's safe area that the floating
    /// bar occupies, without letting the bar itself follow the keyboard's
    /// animated safe-area changes.
    static var safeAreaReservation: some View {
        Color.clear.frame(height: MotionaryPadTabBarMetrics.contentReserve)
    }

    var body: some View {
        MotionaryGlassBarGroup {
            HStack(spacing: 0) {
                GeometryReader { proxy in
                    MotionarySegmentedTabControl(
                        selection: $selection,
                        size: CGSize(
                            width: proxy.size.width - (MotionaryPadTabBarMetrics.controlInset * 2),
                            height: proxy.size.height - (MotionaryPadTabBarMetrics.controlInset * 2)
                        )
                    )
                    .padding(MotionaryPadTabBarMetrics.controlInset)
                    .motionaryInteractiveGlassCapsule()
                }
                .frame(width: MotionaryPadTabBarMetrics.width)

                Spacer(minLength: MotionaryPadTabBarMetrics.minimumAccessorySpacing)

                Button(action: onSearch) {
                    Image(systemName: isSearching ? "keyboard.chevron.compact.down" : "magnifyingglass")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(
                            width: MotionaryPadTabBarMetrics.height,
                            height: MotionaryPadTabBarMetrics.height
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .motionaryInteractiveGlassCapsule()
                .accessibilityLabel(isSearching ? "Close search" : "Search")
                .opacity(isSearchEnabled ? 1 : 0.35)
                .disabled(!isSearchEnabled)
            }
            .frame(height: MotionaryPadTabBarMetrics.height)
            #if os(iOS)
            .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 2)
            #endif
        }
        .padding(.horizontal, MotionaryPadTabBarMetrics.edgePadding)
        .padding(.top, MotionaryPadTabBarMetrics.topPadding)
        // Move the bar without changing its layout bounds. A single animation
        // controls both the keyboard overlap and the extra search clearance.
        .offset(y: -bottomPadding)
        .animation(.easeOut(duration: keyboardAnimationDuration), value: bottomPadding)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear(perform: updateBottomSafeArea)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: keyboardAnimationDuration)) {
                    updateBottomSafeArea()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
            updateKeyboardOverlap(from: $0)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) {
            keyboardWillHide($0)
        }
    }

    private var bottomPadding: CGFloat {
        let base = max(MotionaryPadTabBarMetrics.edgePadding - bottomSafeArea, 0)
        let keyboardLift = keyboardOverlap > 0 ? max(keyboardOverlap - bottomSafeArea, 0) : 0
        let searchLift = isSearching ? MotionaryPadTabBarMetrics.searchKeyboardLift : 0
        return base + keyboardLift + searchLift
    }

    private func updateBottomSafeArea() {
        guard let window = keyWindow else { return }
        let value = window.safeAreaInsets.bottom
        if bottomSafeArea != value {
            withAnimation(.easeOut(duration: max(0.2, keyboardAnimationDuration))) {
                bottomSafeArea = value
            }
        }
    }

    private func updateKeyboardOverlap(from notification: Notification) {
        updateAnimationDuration(from: notification)
        guard
            let window = keyWindow,
            let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        let frameInWindow = window.convert(endFrame, from: window.screen.coordinateSpace)
        // Floating and split keyboards do not cover the bar, so only a
        // keyboard that reaches the bottom edge lifts it.
        let isDocked = frameInWindow.maxY >= window.bounds.maxY - 1
        setKeyboardOverlap(isDocked ? max(0, window.bounds.maxY - frameInWindow.minY) : 0)
    }

    private func keyboardWillHide(_ notification: Notification) {
        updateAnimationDuration(from: notification)
        setKeyboardOverlap(0)
    }

    private func updateAnimationDuration(from notification: Notification) {
        if let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double {
            // Some keyboards report 0; ensure a gentle ease-out fallback.
            keyboardAnimationDuration = max(duration, MotionaryPadTabBarMetrics.defaultKeyboardDuration)
        } else {
            keyboardAnimationDuration = MotionaryPadTabBarMetrics.defaultKeyboardDuration
        }
    }

    /// Applies the overlap change inside an explicit ease-out transaction.
    /// Both directions use the same curve, timed to the keyboard's own
    /// animation, instead of the system's default keyboard spring.
    private func setKeyboardOverlap(_ value: CGFloat) {
        withAnimation(.easeOut(duration: keyboardAnimationDuration)) {
            keyboardOverlap = value
        }
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

private enum MotionaryPadTabBarMetrics {
    static let width: CGFloat = 180
    static let height: CGFloat = 58
    static let controlInset: CGFloat = 3
    static let edgePadding: CGFloat = 20
    static let topPadding: CGFloat = 8
    static let minimumAccessorySpacing: CGFloat = 16
    /// Keeps the bar clear of the on-screen keyboard while search is active.
    static let searchKeyboardLift: CGFloat = 14

    /// Vertical space the bar occupies in the content's safe area.
    static var contentReserve: CGFloat {
        topPadding + height + max(edgePadding - defaultBottomSafeArea, 0)
    }

    /// Typical bottom safe-area inset used before the actual value is read from the window.
    static var defaultBottomSafeArea: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 20 : 34
    }
    
    static let defaultKeyboardDuration: Double = 0.3
}

// MARK: - Segmented control

private struct MotionarySegmentedTabControl: UIViewRepresentable {
    @Binding var selection: Int
    let size: CGSize
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: MotionaryPadTab.allCases.map(\.title))
        control.selectedSegmentIndex = clampedSelection
        control.apportionsSegmentWidthsByContent = false
        context.coordinator.renderBaseImages()
        if #available(iOS 26.0, *) {
            // iOS 26 draws the selection as a separate glass layer, so the
            // control's own segment backgrounds can be hidden. Older systems
            // render the unselected segment through that layer.
            context.coordinator.hideSystemBackground(in: control)
        }
        configureAppearance(control)
        context.coordinator.updateImages(in: control)
        control.addTarget(
            context.coordinator,
            action: #selector(Coordinator.tabSelected(_:)),
            for: .valueChanged
        )
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        _ = colorScheme
        context.coordinator.parent = self
        configureAppearance(control)
        if control.selectedSegmentIndex != clampedSelection {
            control.selectedSegmentIndex = clampedSelection
        }
        context.coordinator.updateImages(in: control)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UISegmentedControl,
        context: Context
    ) -> CGSize? {
        size
    }

    private var clampedSelection: Int {
        min(max(selection, 0), MotionaryPadTab.allCases.count - 1)
    }

    private func configureAppearance(_ control: UISegmentedControl) {
        // The rendered item images carry the accessibility labels, so the
        // control's own titles can stay invisible for an icon-only bar.
        let invisibleTitleAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.label.withAlphaComponent(0.01),
            .font: UIFont.systemFont(ofSize: 0.5)
        ]
        control.setTitleTextAttributes(invisibleTitleAttributes, for: .normal)
        control.setTitleTextAttributes(invisibleTitleAttributes, for: .selected)
        control.selectedSegmentTintColor = selectedTintColor(for: control.traitCollection)
    }

    private func selectedTintColor(for traits: UITraitCollection) -> UIColor {
        switch traits.userInterfaceStyle {
        case .dark:
            return UIColor.black.withAlphaComponent(0.38)
        default:
            return UIColor.label.withAlphaComponent(0.14)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: MotionarySegmentedTabControl
        private var baseImages: [UIImage?] = []
        private var lastSelectedIndex: Int?
        private var lastInterfaceStyle: UIUserInterfaceStyle?

        init(parent: MotionarySegmentedTabControl) {
            self.parent = parent
        }

        @objc func tabSelected(_ control: UISegmentedControl) {
            updateImages(in: control)
            guard MotionaryPadTab.allCases.indices.contains(control.selectedSegmentIndex) else { return }
            parent.selection = control.selectedSegmentIndex
        }

        /// Hides the control's own item backgrounds while preserving the
        /// system's native selection material.
        func hideSystemBackground(in control: UISegmentedControl) {
            DispatchQueue.main.async { [weak control] in
                guard let control else { return }
                for subview in control.subviews {
                    if subview is UIImageView && subview !== control.subviews.last {
                        subview.alpha = 0
                    }
                }
            }
        }

        func renderBaseImages() {
            guard baseImages.isEmpty else { return }
            // The same symbol configuration for both tabs, matching how the
            // native tab bar on iPhone draws its icons, so their relative
            // proportions are identical there instead of being normalized.
            let configuration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
            baseImages = MotionaryPadTab.allCases.map { tab -> UIImage? in
                switch tab {
                case .home:
                    return UIImage(named: "MotionarySF")?.withConfiguration(configuration)
                case .settings:
                    return UIImage(systemName: "gearshape.fill", withConfiguration: configuration)
                }
            }
        }

        func updateImages(in control: UISegmentedControl) {
            let style = control.traitCollection.userInterfaceStyle
            guard lastSelectedIndex != control.selectedSegmentIndex || lastInterfaceStyle != style else { return }
            lastSelectedIndex = control.selectedSegmentIndex
            lastInterfaceStyle = style

            let accent = UIColor(MotionaryTheme.accent).resolvedColor(with: control.traitCollection)
            let normal = UIColor.secondaryLabel.resolvedColor(with: control.traitCollection)
            for (index, image) in baseImages.enumerated() {
                // Original-mode images avoid UIKit accumulating its selection tint.
                let color = index == control.selectedSegmentIndex ? accent : normal
                let tinted = image?.withTintColor(color, renderingMode: .alwaysOriginal)
                tinted?.accessibilityLabel = MotionaryPadTab.allCases[index].title
                control.setImage(tinted, forSegmentAt: index)
            }
        }
    }
}

// MARK: - Glass treatment

private struct MotionaryGlassBarGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { content() }
        } else {
            content()
        }
    }
}

private struct MotionaryInteractiveGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}

private extension View {
    func motionaryInteractiveGlassCapsule() -> some View {
        modifier(MotionaryInteractiveGlassCapsule())
    }
}
