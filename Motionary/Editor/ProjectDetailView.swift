import SwiftUI

struct ProjectDetailView: View {
    var project: Project
    @ObservedObject var projectStore: ProjectStore
    
    // Holds the imported video's URL and duration (in seconds)
    @State private var importedVideoURL: URL? = nil
    @State private var videoDuration: Double = 0.0
    @State private var projectContent: ProjectContent? = nil

    var body: some View {
        VStack {
            if let content = projectContent {
                ProjectEditorView(projectID: project.id, projectStore: projectStore, initialContent: content)
            } else if importedVideoURL != nil {
                Text("Preparing project...")
                    .foregroundColor(.white)
            } else {
                // Otherwise, show the import screen.
                ImportFootageView { url, duration in
                    let storedURL = projectStore.storeMedia(from: url, projectID: project.id)
                    let initialClip = Clip(sourceURL: storedURL, startTime: 0, endTime: duration, mediaType: .video)
                    let content = ProjectContent(
                        clips: [initialClip],
                        keyframes: [],
                        selectedEffect: .none,
                        effectIntensity: 0.6
                    )
                    projectStore.saveContent(content, for: project.id)
                    importedVideoURL = url
                    videoDuration = duration
                    projectContent = content
                }
            }
        }
        .navigationTitle(project.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if projectContent == nil {
                projectContent = projectStore.loadContent(for: project.id)
            }
        }
    }
}
