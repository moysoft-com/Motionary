// Project-to-editor navigation adapter.

import SwiftUI

/// Loads persisted project content and presents the editor.
struct ProjectDetailView: View {
    var project: Project
    @ObservedObject var projectStore: ProjectStore
    let initialContent: ProjectContent
    let onClose: () -> Void
    @State private var content: ProjectContent
    @State private var loadError: String?

    init(
        project: Project,
        projectStore: ProjectStore,
        initialContent: ProjectContent,
        onClose: @escaping () -> Void
    ) {
        self.project = project
        self.projectStore = projectStore
        self.initialContent = initialContent
        self.onClose = onClose
        _content = State(initialValue: initialContent)
    }

    var body: some View {
        Group {
            if loadError == nil {
                ProjectEditorView(
                    projectID: project.id,
                    projectStore: projectStore,
                    initialContent: content,
                    onClose: onClose
                )
                .id(content.editorProject.updatedAt)
            } else if let loadError {
                ContentUnavailableView(
                    "Project unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            }
        }
        .navigationTitle(project.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "chevron.left")
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Back to projects")
                .accessibilityIdentifier("motionary-editor-back")
            }
        }
        .task(id: project.id) {
            do {
                let loadedContent = try await projectStore.repository.load(
                    projectID: project.id,
                    preferredTitle: project.title
                ).content
                projectStore.recordSavedContent(loadedContent, projectID: project.id)
                if content != loadedContent {
                    content = loadedContent
                }
            } catch ProjectRepositoryError.missingContent {
                content = ProjectContent(editorProject: EditorProject.empty(title: project.title))
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}
