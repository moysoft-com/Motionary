// Project-to-editor navigation adapter.

import SwiftUI

/// Loads persisted project content and presents the editor.
struct ProjectDetailView: View {
    var project: Project
    @ObservedObject var projectStore: ProjectStore

    var body: some View {
        Group {
            ProjectEditorView(
                projectID: project.id,
                projectStore: projectStore,
                initialContent: projectStore.loadContent(for: project.id)
                    ?? ProjectContent(editorProject: EditorProject.empty(title: project.title))
            )
        }
        .navigationTitle(project.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
