// Application entry point and root tab structure.

import FirebaseAppCheck
import FirebaseCore
import SwiftUI
import TipKit
import UIKit

private final class MotionaryAppAttestProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        return AppAttestProvider(app: app)
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    private var videoLandscapeEnabled = false

    func application(
        _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return videoLandscapeEnabled ? .allButUpsideDown : .portrait
    }

    func setVideoLandscapeEnabled(_ enabled: Bool) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        videoLandscapeEnabled = enabled
        if enabled {
            updateVideoOrientationSupport()
        } else {
            requestVideoOrientation(.portrait)
        }
    }

    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.keyWindow != nil }
    }

    private func updateVideoOrientationSupport() {
        var controller = activeWindowScene?.keyWindow?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
    }

    private func requestVideoOrientation(_ mask: UIInterfaceOrientationMask) {
        updateVideoOrientationSupport()
        activeWindowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            AppLogger.lifecycle.debug("Video orientation request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

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
        do {
            try Tips.configure([.displayFrequency(.hourly)])
        } catch {
            AppLogger.lifecycle.error("TipKit configuration failed: \(error.localizedDescription, privacy: .public)")
        }
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
    @State private var incomingProjectID: UUID?
    @State private var openedVideo: MotionaryVideoArchive.Movie?
    @State private var presentedVideo: MotionaryVideoArchive.Movie?
    @State private var documentError: String?
    @State private var whatsNewRelease: WhatsNewRelease?
    @State private var checkedWhatsNewThisLaunch = false
    @AppStorage("motionary.whatsNew.acknowledgedVersions")
    private var acknowledgedReleases = ""
    private struct IncomingDocument {
        let url: URL
        var sharedProjectID: UUID?
    }

    @State private var documentQueue: [IncomingDocument] = []
    @State private var openingDocumentURL: URL?
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
                } else if let fixture = ProcessInfo.processInfo.environment["MOTIONARY_EDITOR_UI_FIXTURE"] {
                    NavigationStack { ArchivedEditorTestScene(url: URL(fileURLWithPath: fixture), store: projectStore) }
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
        .modifier(SuggestionsShakeShortcut(surface: selectedTab == 1 ? .settings : isEditorPresented ? .editor : .projects))
        .onOpenURL { url in
            guard url.isFileURL, ["mpj", MotionaryVideoArchive.fileExtension].contains(url.pathExtension.lowercased()) else { return }
            guard openingDocumentURL != url, !documentQueue.contains(where: { $0.url == url }) else { return }
            documentQueue.append(IncomingDocument(url: url))
            openNextDocument()
        }
        .fullScreenCover(item: $openedVideo, onDismiss: {
            delegate.setVideoLandscapeEnabled(false)
            presentedVideo?.removeTemporaryFiles()
            presentedVideo = nil
            openNextDocument()
        }) { movie in
            MotionaryVideoPlayer(movie: movie)
        }
        .fullScreenCover(item: $whatsNewRelease, onDismiss: {
            openNextDocument()
            handlePendingAction()
        }) { release in
            WhatsNewView(release: release, onAcknowledge: { acknowledgeWhatsNew(release) })
        }
        .alert("Couldn’t Open File", isPresented: Binding(
            get: { documentError != nil },
            set: { if !$0 { documentError = nil } }
        )) {
            Button("OK", role: .cancel) { documentError = nil; openNextDocument() }
        } message: {
            Text(documentError ?? "")
        }
        .overlay {
            if openingDocumentURL != nil {
                MotionaryProjectLoadingView(title: "Opening File")
            }
        }
        .onAppear {
            rootViewAppeared = true
            collectSharedProjects()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { collectSharedProjects() }
        }
        .onDisappear { rootViewAppeared = false }
        .task(id: rootViewAppeared && scenePhase == .active) {
            // Let the root collect shared projects and receive any launch intent first.
            await Task.yield()
            guard !Task.isCancelled else { return }
            presentWhatsNewIfNeeded()
        }
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
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                iPadTabs.ignoresSafeArea(.keyboard, edges: .bottom)
            } else {
                phoneTabs
                    .ignoresSafeArea(.container)
            }
        }
        .sensoryFeedback(.selection, trigger: selectedTab)
        .onChange(of: selectedTab) { _, tab in
            if tab == 1 {
                isProjectSearchPresented = false
                projectSearchText = ""
            }
        }
    }

    private var phoneTabs: some View {
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
                incomingProjectID: $incomingProjectID,
                searchText: $projectSearchText,
                isSearchPresented: $isProjectSearchPresented,
                onEditorPresentationChange: { isEditorPresented = $0 }
            )
        } settings: {
            SettingsView()
        }
    }

    private var iPadTabs: some View {
        ZStack {
            HomeView(
                projectStore: projectStore,
                newProjectRequest: newProjectRequest,
                incomingProjectID: $incomingProjectID,
                searchText: $projectSearchText,
                isSearchPresented: $isProjectSearchPresented,
                onEditorPresentationChange: { isEditorPresented = $0 }
            )
            .opacity(selectedTab == 0 ? 1 : 0)
            .allowsHitTesting(selectedTab == 0)
            .accessibilityHidden(selectedTab != 0)

            SettingsView()
                .opacity(selectedTab == 1 ? 1 : 0)
                .allowsHitTesting(selectedTab == 1)
                .accessibilityHidden(selectedTab != 1)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .tint(.primary)
        .modifier(PadTabBarPlacement(isEditorPresented: isEditorPresented, selection: $selectedTab,
                                     isSearching: isProjectSearchPresented, onSearch: handlePadSearch))
    }

    private struct PadTabBarPlacement: ViewModifier {
        let isEditorPresented: Bool
        @Binding var selection: Int
        let isSearching: Bool
        let onSearch: () -> Void

        func body(content: Content) -> some View {
            reservedContent(content)
                .overlay(alignment: .bottom) {
                    if !isEditorPresented {
                        MotionaryPadTabBar(
                            selection: $selection,
                            isSearching: isSearching,
                            onSearch: onSearch
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
        }

        @ViewBuilder
        private func reservedContent(_ content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content.safeAreaBar(edge: .bottom, spacing: 0) { MotionaryPadTabBar.safeAreaReservation }
            } else {
                content.safeAreaInset(edge: .bottom, spacing: 0) { MotionaryPadTabBar.safeAreaReservation }
            }
        }
    }

    private func handlePadSearch() {
        if isProjectSearchPresented {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        selectedTab = 0
        isProjectSearchPresented.toggle()
        if !isProjectSearchPresented { projectSearchText = "" }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func collectSharedProjects() {
        for url in MotionaryShareInbox.pendingProjects() {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                openingDocumentURL != url,
                !documentQueue.contains(where: { $0.url == url })
            else { continue }
            documentQueue.append(IncomingDocument(url: url, sharedProjectID: id))
        }
        openNextDocument()
    }

    private func openNextDocument() {
        guard rootViewAppeared, openingDocumentURL == nil, presentedVideo == nil, documentError == nil,
            whatsNewRelease == nil, !documentQueue.isEmpty
        else { return }
        let document = documentQueue.removeFirst()
        let url = document.url
        openingDocumentURL = url
        Task { @MainActor in
            defer {
                if document.sharedProjectID != nil {
                    try? FileManager.default.removeItem(at: url)
                }
                openingDocumentURL = nil
                openNextDocument()
            }
            do {
                if url.pathExtension.lowercased() == MotionaryVideoArchive.fileExtension {
                    let movie = try await MotionaryVideoArchive.open(url)
                    presentedVideo = movie
                    delegate.setVideoLandscapeEnabled(true)
                    openedVideo = movie
                } else {
                    let projectID = document.sharedProjectID ?? UUID()
                    try await projectStore.importArchive(at: url, id: projectID)
                    selectedTab = 0
                    projectSearchText = ""
                    isProjectSearchPresented = false
                    incomingProjectID = projectID
                }
            } catch {
                documentError = error.localizedDescription
            }
        }
    }

    private func handlePendingAction() {
        guard rootViewAppeared, scenePhase == .active, whatsNewRelease == nil,
            let action = actions.pendingAction
        else { return }
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

    private func presentWhatsNewIfNeeded() {
        guard rootViewAppeared, scenePhase == .active, !checkedWhatsNewThisLaunch else { return }
        checkedWhatsNewThisLaunch = true

        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            guard !arguments.contains("--skip-whats-new") else { return }
            let preview = arguments.contains("--preview-whats-new")
        #else
            let preview = false
        #endif

        guard selectedTab == 0, actions.pendingAction == nil, newProjectRequest == nil,
            !isProjectSearchPresented, !isEditorPresented, !iconPickerPresented,
            incomingProjectID == nil, documentQueue.isEmpty, openingDocumentURL == nil,
            presentedVideo == nil, documentError == nil,
            let release = WhatsNewRelease.current(),
            preview || !acknowledgedReleases.split(separator: ",").contains(Substring(release.version))
        else { return }
        whatsNewRelease = release
    }

    private func acknowledgeWhatsNew(_ release: WhatsNewRelease) {
        #if DEBUG
            guard !ProcessInfo.processInfo.arguments.contains("--preview-whats-new") else { return }
        #endif
        var versions = Set(acknowledgedReleases.split(separator: ",").map(String.init))
        versions.insert(release.version)
        acknowledgedReleases = versions.sorted().joined(separator: ",")
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
