// Application entry point and root tab structure.

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
        if let shortcut = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            HomeScreenActions.shared.receive(shortcut)
        }
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
    @State private var projectSearchText = ""
    @State private var isProjectSearchPresented = false
    @State private var isEditorPresented = false
    @StateObject private var projectStore = ProjectStore()
    @State private var iconPickerPresented = false
    @State private var rootViewAppeared = false
    @State private var newProjectRequest: UUID?
    @AppStorage(AppPreferences.appearanceKey)
    private var appearance = AppPreferences.defaultAppearance


    var body: some Scene {
        WindowGroup {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--effects-gesture-tests") {
                    ProjectTabController(
                        selection: .constant(0), isSearching: false, isEditorPresented: true,
                        homeRevision: nil, onSearch: {}, onLeaveHome: {},
                        home: { EffectsGestureTestScene() }, settings: { Text("Settings") }
                    )
                    .ignoresSafeArea(.container)
                } else if ProcessInfo.processInfo.arguments.contains("--adjustment-editor-tests") {
                    NavigationStack { AdjustmentEditorTestScene() }
                } else if ProcessInfo.processInfo.arguments.contains("--timeline-gesture-tests") {
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
            if #available(iOS 26.0, *) {
                tabView.scrollEdgeEffectStyle(.soft, for: .all)
            } else {
                tabView
            }
        }
        .sheet(isPresented: $iconPickerPresented) {
            AppIconPickerView()
        }
        .onAppear { rootViewAppeared = true }
        .onDisappear { rootViewAppeared = false }
        .task(id: rootViewAppeared && scenePhase == .active ? actions.pendingAction?.rawValue : nil) {
            // Cold-launch actions can arrive before SwiftUI has a presenter.
            // Keep the action queued until the root is attached and active.
            await Task.yield()
            guard !Task.isCancelled else { return }
            handlePendingAction()
        }
        .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
    }

    private var tabView: some View {
        ProjectTabController(selection: $selectedTab, isSearching: isProjectSearchPresented, isEditorPresented: isEditorPresented, homeRevision: newProjectRequest, onSearch: {
            selectedTab = 0
            isProjectSearchPresented.toggle()
            if !isProjectSearchPresented { projectSearchText = "" }
        }, onLeaveHome: {
            isProjectSearchPresented = false
            projectSearchText = ""
        }) {
            HomeView(
                projectStore: projectStore,
                newProjectRequest: newProjectRequest,
                searchText: $projectSearchText,
                isSearchPresented: $isProjectSearchPresented,
                onEditorPresentationChange: { isEditorPresented = $0 }
            )
        } settings: {
            SettingsView()
        }
        // The UIKit container owns the system-bar insets for its hosted screens.
        // Give it the full window instead of insetting it again in SwiftUI.
        .ignoresSafeArea(.container)
        .sensoryFeedback(.selection, trigger: selectedTab)
        .onChange(of: selectedTab) { _, tab in
            if tab == 1 {
                isProjectSearchPresented = false
                projectSearchText = ""
            }
        }
    }

    private func handlePendingAction() {
        guard rootViewAppeared, scenePhase == .active, let action = actions.pendingAction else { return }
        AppLogger.lifecycle.info("Presenting Home Screen action: \(action.rawValue, privacy: .public)")
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

/// The UIKit/SwiftUI boundary applies one content tint policy on both idioms.
/// Individual accent controls can still opt in locally.
struct RootTabContent<Content: View>: View {
    let content: Content
    var body: some View { content.tint(.primary) }
}

/// Uses UIKit's selection veto so the native search tab acts on the existing home controller.
/// SwiftUI's TabView selection binding cannot veto a tab's presentation reliably.
struct ProjectTabController<Home: View, Settings: View>: UIViewControllerRepresentable {
    @Binding var selection: Int
    let isSearching: Bool
    let isEditorPresented: Bool
    let homeRevision: UUID?
    let onSearch: () -> Void
    let onLeaveHome: () -> Void
    @ViewBuilder let home: () -> Home
    @ViewBuilder let settings: () -> Settings

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        let coordinator = context.coordinator
        let homeController = UIHostingController(rootView: RootTabContent(content: home()))
        let settingsController = UIHostingController(rootView: RootTabContent(content: settings()))
        coordinator.homeController = homeController
        coordinator.lastHomeRevision = homeRevision
        coordinator.settingsController = settingsController
        let homeTab = UITab(title: "Motionary", image: UIImage(named: "MotionarySF"), identifier: "home") { _ in
            homeController
        }
        let settingsTab = UITab(title: "Settings", image: UIImage(systemName: "gearshape.fill"), identifier: "settings") { _ in
            settingsController
        }
        // UIKit resolves every root tab's controller during installation, even if
        // its selection is vetoed. This controller is never presented.
        let searchTab = UISearchTab { _ in UIViewController() }
        coordinator.homeTab = homeTab
        coordinator.settingsTab = settingsTab
        coordinator.searchTab = searchTab
        controller.tabs = [homeTab, settingsTab, searchTab]
        configureRootTabBarItems(controller.tabBar)
        if #available(iOS 27.0, *) {
            controller.prominentTabIdentifier = searchTab.identifier
        }
        controller.delegate = coordinator
        controller.selectedTab = selection == 1 ? settingsTab : homeTab
        // The content hierarchy is neutral on every idiom. Tab styling stays
        // on the tab bar rather than propagating into hosted screens/sheets.
        controller.view.tintColor = .label
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        let accent = UIColor(MotionaryTheme.accent)
        for itemAppearance in [
            appearance.stackedLayoutAppearance,
            appearance.inlineLayoutAppearance,
            appearance.compactInlineLayoutAppearance,
        ] {
            itemAppearance.selected.iconColor = accent
            itemAppearance.selected.titleTextAttributes = [.foregroundColor: accent]
        }
        controller.tabBar.standardAppearance = appearance
        controller.tabBar.scrollEdgeAppearance = appearance
        controller.tabBar.tintColor = accent
        return controller
    }

    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        configureRootTabBarItems(controller.tabBar)
        if controller.isTabBarHidden != isEditorPresented {
            controller.setTabBarHidden(isEditorPresented, animated: false)
        }
        if coordinator.lastSearchState != isSearching {
            let symbol = isSearching ? "keyboard.chevron.compact.down" : "magnifyingglass"
            let title = isSearching ? "Close search" : "Search"
            let icon = UIImage(systemName: symbol)
            coordinator.searchTab?.image = icon
            coordinator.searchTab?.title = title
            if let item = controller.tabBar.items?.last {
                item.title = title
                item.image = icon
                item.accessibilityLabel = title
            }
            coordinator.lastSearchState = isSearching
        }
        // Bindings and ObservableObject update Home in its own hosting tree.
        // Only the value-type new-project request requires a new root value.
        if coordinator.lastHomeRevision != homeRevision {
            coordinator.homeController?.rootView = RootTabContent(content: home())
            coordinator.lastHomeRevision = homeRevision
        }
        let target = selection == 1 ? coordinator.settingsTab : coordinator.homeTab
        if controller.selectedTab !== target {
            controller.selectedTab = target
        }
    }

    /// Hide labels only on the app's root tabs. Keeping the accessibility labels
    /// lets VoiceOver identify each icon while hosted subviews retain their own
    /// SwiftUI label styles.
    private func configureRootTabBarItems(_ tabBar: UITabBar) {
        guard let items = tabBar.items, items.count >= 2 else { return }
        items[0].title = ""
        items[0].accessibilityLabel = "Motionary"
        items[1].title = ""
        items[1].accessibilityLabel = "Settings"
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate {
        var parent: ProjectTabController
        var lastSearchState: Bool?
        var lastHomeRevision: UUID?
        var homeController: UIHostingController<RootTabContent<Home>>?
        var settingsController: UIHostingController<RootTabContent<Settings>>?
        var homeTab: UITab?
        var settingsTab: UITab?
        var searchTab: UISearchTab?

        init(parent: ProjectTabController) { self.parent = parent }

        func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
            if tab === searchTab {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if parent.isSearching { tabBarController.view.endEditing(true) }
                // Finish UIKit's selection decision before changing the active tab.
                DispatchQueue.main.async { [weak self, weak tabBarController] in
                    guard let self, let tabBarController else { return }
                    tabBarController.selectedTab = self.homeTab
                    self.parent.onSearch()
                }
                return false
            }
            return true
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
            parent.selection = selectedTab === settingsTab ? 1 : 0
            parent.onLeaveHome()
        }
    }
}
