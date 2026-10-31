import SwiftUI
import Testing
import UIKit

@testable import Motionary

@Suite(.serialized)
struct RootTabTintTests {
    @MainActor
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func rootAccentIsConfinedToTabsAndDoesNotReachHostedOrPresentedContent(style: UIUserInterfaceStyle) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let content = ProjectTabController(
            selection: .constant(0), isSearching: false, isEditorPresented: false,
            homeRevision: nil, onSearch: {}, onLeaveHome: {},
            home: { VStack { Text("Home"); RootTintProbe() } }, settings: { Text("Settings") }
        )
        let host = UIHostingController(rootView: content)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        func controllers(_ controller: UIViewController) -> [UIViewController] {
            [controller] + controller.children.flatMap { controllers($0) }
        }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { views($0) } }
        let tabs = try #require(controllers(host).compactMap { $0 as? UITabBarController }.first)
        let traits = tabs.traitCollection
        let neutral = UIColor.label.resolvedColor(with: traits)
        #expect(sameColor(tabs.view.tintColor, neutral, traits: traits))
        #expect(tabs.tabBar.tintColor.isEqual(UIColor(MotionaryTheme.accent)))
        let home = try #require(tabs.selectedViewController)
        #expect(sameColor(home.view.tintColor, neutral, traits: traits))
        let homeProbe = try #require(views(home.view).compactMap { $0 as? UIButton }.first)
        #expect(sameColor(homeProbe.tintColor, neutral, traits: homeProbe.traitCollection))
        let sheet = UIHostingController(rootView: RootTabContent(content: RootTintProbe()))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            home.present(sheet, animated: false) { continuation.resume() }
        }
        let probe = try #require(views(sheet.view).compactMap { $0 as? UIButton }.first)
        #expect(sameColor(
            probe.tintColor, UIColor.label, traits: probe.traitCollection
        ))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            home.dismiss(animated: false) { continuation.resume() }
        }
    }

    private func sameColor(_ lhs: UIColor, _ rhs: UIColor, traits: UITraitCollection) -> Bool {
        var leftRed: CGFloat = 0
        var leftGreen: CGFloat = 0
        var leftBlue: CGFloat = 0
        var leftAlpha: CGFloat = 0
        var rightRed: CGFloat = 0
        var rightGreen: CGFloat = 0
        var rightBlue: CGFloat = 0
        var rightAlpha: CGFloat = 0
        let leftResolved = lhs.resolvedColor(with: traits)
        let rightResolved = rhs.resolvedColor(with: traits)
        guard leftResolved.getRed(&leftRed, green: &leftGreen, blue: &leftBlue, alpha: &leftAlpha),
              rightResolved.getRed(&rightRed, green: &rightGreen, blue: &rightBlue, alpha: &rightAlpha)
        else { return false }
        return abs(leftRed - rightRed) < 0.001
            && abs(leftGreen - rightGreen) < 0.001
            && abs(leftBlue - rightBlue) < 0.001
            && abs(leftAlpha - rightAlpha) < 0.001
    }
}

private struct RootTintProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle("Neutral sheet action", for: .normal)
        return button
    }
    func updateUIView(_ view: UIButton, context: Context) {}
}
