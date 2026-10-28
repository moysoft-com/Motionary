// Application entry point and root tab structure. 😳

import FirebaseAppCheck
import FirebaseCore
import SwiftUI
import UIKit

private final class MotionaryAppAttestProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        return AppAttestProvider(app: app)
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if DEBUG
            AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
            AppCheck.setAppCheckProviderFactory(MotionaryAppAttestProviderFactory())
        #endif
        FirebaseApp.configure()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let shortcut = options.shortcutItem {
            HomeScreenActions.shared.receive(shortcut)
        }
        let configuration = connectingSceneSession.configuration
        configuration.delegateClass = HomeScreenShortcutDelegate.self
        return configuration
    }
}

/// Forwards quick actions from both new and restored scene sessions to SwiftUI.
final class HomeScreenShortcutDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let shortcut = connectionOptions.shortcutItem {
            HomeScreenActions.shared.receive(shortcut)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(HomeScreenActions.shared.receive(shortcutItem))
    }
}

@main
/// Launches Motionary and installs the project and settings tabs.
struct MainView: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var actions = HomeScreenActions.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var iconPickerPresented = false
    @State private var newProjectRequest: UUID?
    @AppStorage(AppPreferences.appearanceKey)
    private var appearance = AppPreferences.defaultAppearance

    init() {
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithDefaultBackground()
        let accent = UIColor(MotionaryTheme.accent)

        tabBarAppearance.stackedLayoutAppearance.selected.iconColor = accent
        tabBarAppearance.inlineLayoutAppearance.selected.iconColor = accent
        tabBarAppearance.compactInlineLayoutAppearance.selected.iconColor = accent

        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--timeline-gesture-tests") {
                    TimelineGestureTestScene()
                } else {
                    appTabs
                }
            #else
                appTabs
            #endif
        }
    }

    private var appTabs: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                if #available(iOS 26.0, *) {
                    tabView.tint(MotionaryTheme.accent)
                        .scrollEdgeEffectStyle(.soft, for: .all)
                } else {
                    tabView.tint(MotionaryTheme.accent)
                }
            } else {
                if #available(iOS 26.0, *) {
                    tabView
                        .scrollEdgeEffectStyle(.soft, for: .all)
                } else {
                    tabView
                }
            }
        }
        .sheet(isPresented: $iconPickerPresented) {
            AppIconPickerView()
        }
        .onChange(of: actions.pendingAction, initial: true) { _, _ in
            handlePendingAction()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { handlePendingAction() }
        }
        .labelStyle(.iconOnly)
        .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
    }

    private var tabView: some View {
        TabView(selection: $selectedTab) {
            Tab(value: 0) {
                HomeView(newProjectRequest: newProjectRequest)
                    .tint(nil)
                    .labelStyle(.automatic)
            } label: {
                Image("MotionarySF")
            }

            Tab("Settings", systemImage: "gearshape.fill", value: 1) {
                SettingsView()
                    .tint(nil)
            }
        }
    }

    private func handlePendingAction() {
        guard scenePhase == .active, let action = actions.pendingAction else { return }
        actions.pendingAction = nil
        switch action {
        case .changeIcon:
            iconPickerPresented = true
        case .newProject:
            iconPickerPresented = false
            selectedTab = 0
            newProjectRequest = UUID()
        case .settings:
            iconPickerPresented = false
            selectedTab = 1
        }
    }
}
