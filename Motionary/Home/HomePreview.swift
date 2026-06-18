// Development-only sample data and SwiftUI preview for the project dashboard.

import SwiftUI

extension ProjectStore {
    static func mockWithProjects() -> ProjectStore {
        let store = ProjectStore()
        store.projects = [
            Project(id: UUID(), title: "Demo Project", updatedAt: .now)
        ]
        return store
    }
}

#Preview {
    HomeView(projectStore: .mockWithProjects())
}
