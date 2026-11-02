import SwiftUI
import UIKit

/// A retained action survives launch until the SwiftUI scene is ready to present it.
@MainActor
final class HomeScreenActions: ObservableObject {
    enum Action: String {
        case changeIcon = "com.moysoft.motionary.change-icon"
        case newProject = "com.moysoft.motionary.new-project"
        case settings = "com.moysoft.motionary.settings"
    }

    static let shared = HomeScreenActions()
    @Published var pendingAction: Action?

    @discardableResult
    func receive(_ shortcut: UIApplicationShortcutItem) -> Bool {
        guard let action = Action(rawValue: shortcut.type) else { return false }
        AppLogger.lifecycle.info("Received Home Screen action: \(action.rawValue, privacy: .public)")
        pendingAction = action
        return true
    }
}
