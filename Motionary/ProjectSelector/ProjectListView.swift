import SwiftUI

struct ProjectListView: View {
    @State private var projects: [Project] = []
    @State private var showRenameSheet = false
    @State private var projectToRename: Project?
    @State private var tempName: String = ""
    @State private var showMediaImport = false
    @State private var tempMedia: [URL] = []

    var onProjectSelect: (Project) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                Text("Motionary")
                    .font(.largeTitle)
                    .foregroundColor(.white)
                    .padding(.top, 20)

                Button(action: createNewProject) {
                    Text("Create New Project")
                        .foregroundColor(.black)
                        .padding()
                        .background(Color.white)
                        .cornerRadius(8)
                }
                .padding(.vertical, 20)

                if projects.isEmpty {
                    Text("No projects yet.")
                        .foregroundColor(.white)
                        .padding()
                } else {
                    let columns = [GridItem(.flexible()), GridItem(.flexible())]
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(projects) { project in
                                ZStack(alignment: .topTrailing) {
                                    Button {
                                        onProjectSelect(project)
                                    } label: {
                                        VStack {
                                            Text(project.name)
                                                .font(.headline)
                                                .foregroundColor(.white)
                                                .padding(.bottom, 4)
                                            Text(project.creationDate, style: .date)
                                                .font(.subheadline)
                                                .foregroundColor(.gray)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 100)
                                        .background(Color.gray.opacity(0.2))
                                        .cornerRadius(8)
                                    }
                                    Menu {
                                        Button("Rename") {
                                            projectToRename = project
                                            tempName = project.name
                                            showRenameSheet = true
                                        }
                                        Button("Delete", role: .destructive) {
                                            deleteProject(project)
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .foregroundColor(.white)
                                            .padding(8)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                Spacer()
            }
        }
        .onAppear { loadProjects() }
        .sheet(isPresented: $showRenameSheet) {
            NavigationView {
                Form {
                    Section(header: Text("Rename Project")) {
                        TextField("Project Name", text: $tempName)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                }
                .navigationBarItems(
                    leading: Button("Cancel") { showRenameSheet = false },
                    trailing: Button("Save") {
                        if let oldProject = projectToRename,
                           let index = projects.firstIndex(where: { $0.id == oldProject.id }) {
                            projects[index].name = tempName
                            saveProjects()
                        }
                        showRenameSheet = false
                    }
                )
            }
        }
        .sheet(isPresented: $showMediaImport) {
            MediaImportView(importedMedia: $tempMedia)
                .onDisappear {
                    if var lastProject = projects.last {
                        lastProject.mediaPaths = tempMedia.map { $0.absoluteString }
                        saveProjects()
                    }
                    tempMedia.removeAll()
                }
        }
    }

    private func createNewProject() {
        let newProject = Project(name: "My New Project \(projects.count + 1)")
        projects.append(newProject)
        saveProjects()
        showMediaImport = true
    }

    private func deleteProject(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects.remove(at: index)
            saveProjects()
        }
    }

    private func loadProjects() {
        if let data = UserDefaults.standard.data(forKey: "savedProjects"),
           let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            projects = decoded
        }
    }

    private func saveProjects() {
        if let data = try? JSONEncoder().encode(projects) {
            UserDefaults.standard.set(data, forKey: "savedProjects")
        }
    }
}