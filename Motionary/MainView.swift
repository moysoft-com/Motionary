// Application entry point and root tab structure. 😳

import SwiftUI
import FirebaseAppCheck
import FirebaseCore

private final class MotionaryAppAttestProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        return AppAttestProvider(app: app)
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        #if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        AppCheck.setAppCheckProviderFactory(MotionaryAppAttestProviderFactory())
        #endif
        FirebaseApp.configure()
        return true
    }
}

@main
/// Launches Motionary and installs the project and settings tabs.
struct MainView: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage(AppPreferences.appearanceKey)
    private var appearance = AppPreferences.defaultAppearance

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab {
                    HomeView()
                        .labelStyle(.automatic)
                } label: {
                    Image("MotionarySF")
                }

                Tab("Settings", systemImage: "gearshape.fill") {
                    SettingsView()
                }
            }
            .labelStyle(.iconOnly)
            .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
        }
    }
}
