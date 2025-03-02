import SwiftUI

struct ProjectDetailView: View {
    var project: Project
    
    // Holds the imported video's URL and duration (in seconds)
    @State private var importedVideoURL: URL? = nil
    @State private var videoDuration: Double = 0.0

    var body: some View {
        VStack {
            if let videoURL = importedVideoURL {
                // Once media is imported, show the editor.
                ProjectEditorView(initialVideoURL: videoURL, initialDuration: videoDuration)
            } else {
                // Otherwise, show the import screen.
                ImportFootageView { url, duration in
                    // When import completes successfully, store the values.
                    importedVideoURL = url
                    videoDuration = duration
                }
            }
        }
        .navigationTitle(project.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
