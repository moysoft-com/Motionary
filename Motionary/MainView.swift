// Application entry point and root tab structure. test 😳

import SwiftUI

@main
/// Launches Motionary and installs the project and settings tabs.
struct MainView: App {
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
                    EmptyView()
                }
            }
            .labelStyle(.iconOnly)
        }
    }
}
