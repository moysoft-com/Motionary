import SwiftUI

struct MainView: View {
    @State private var selectedProject: Project? = nil

    var body: some View {
        NavigationView {
            if let project = selectedProject {
                EditorView(project: project) {
                    selectedProject = nil
                }
            } else {
                ProjectListView { project in
                    selectedProject = project
                }
            }
        }
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView()
    }
}