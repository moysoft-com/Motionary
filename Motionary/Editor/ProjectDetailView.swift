// Project-to-editor navigation adapter.

import SwiftUI

/// Loads persisted project content and presents the editor.
struct ProjectDetailView: View {
    var project: Project
    @ObservedObject var projectStore: ProjectStore
    @State private var content: ProjectContent?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let content {
                ProjectEditorView(
                    projectID: project.id,
                    projectStore: projectStore,
                    initialContent: content
                )
            } else if let loadError {
                ContentUnavailableView(
                    "Project unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView("Loading Project")
            }
        }
        .navigationTitle(project.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: project.id) {
            do {
                content = try await projectStore.repository.load(projectID: project.id).content
            } catch ProjectRepositoryError.missingContent {
                content = ProjectContent(editorProject: EditorProject.empty(title: project.title))
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}
