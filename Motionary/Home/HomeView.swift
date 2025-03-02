import SwiftUI

struct Project: Identifiable, Equatable {
    let id = UUID()
    var title: String
}

struct HomeView: View {
    // List of projects
    @State private var projects: [Project] = []
    
    // Controls navigation to the project detail view
    @State private var showEditor = false
    @State private var selectedProject: Project? = nil
    
    // Tracks which project (if any) is currently being renamed
    @State private var editingProjectID: UUID? = nil
    
    var body: some View {
        NavigationView {
            ZStack {
                // Black background
                Color.black
                    .ignoresSafeArea()
                
                VStack(spacing: 20) {
                    // App title at the top (white text)
                    Text("MOTIONARY")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.top, 40)
                    
                    // White, rounded "Create Project" button
                    Button(action: {
                        // Create a new project
                        let newProject = Project(title: "Project #\(projects.count + 1)")
                        projects.append(newProject)
                        
                        // Immediately open the new project detail view
                        selectedProject = newProject
                        showEditor = true
                    }) {
                        Text("Create Project")
                            .fontWeight(.semibold)
                            .padding()
                            .background(Color.white)
                            .foregroundColor(.black)
                            .cornerRadius(8)
                    }
                    
                    // Two columns of rounded project cards
                    // Each card shows a title and a 3-dot menu.
                    // Tapping a card opens the project detail view.
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ],
                        spacing: 20
                    ) {
                        ForEach($projects) { $project in
                            ZStack(alignment: .topLeading) {
                                // Rounded white background
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.white)
                                
                                // Title display or inline renaming TextField
                                VStack(alignment: .leading, spacing: 8) {
                                    if editingProjectID == project.id {
                                        TextField("Project Title", text: $project.title) {
                                            editingProjectID = nil
                                        }
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                    } else {
                                        Text(project.title)
                                            .font(.headline)
                                            .foregroundColor(.black)
                                    }
                                    Spacer()
                                }
                                .padding()
                                
                                // Three-dot menu in the top-right corner
                                HStack {
                                    Spacer()
                                    Menu {
                                        Button("Rename") {
                                            editingProjectID = project.id
                                        }
                                        Button(role: .destructive) {
                                            projects.removeAll { $0.id == project.id }
                                        } label: {
                                            Text("Delete")
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .foregroundColor(.black)
                                            .padding()
                                    }
                                }
                                .padding(.top, 4)
                                .padding(.trailing, 4)
                            }
                            .frame(height: 100)
                            .onTapGesture {
                                selectedProject = project
                                showEditor = true
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    // Navigation link to the project detail view.
                    NavigationLink(
                        destination: Group {
                            if let project = selectedProject {
                                ProjectDetailView(project: project)
                            } else {
                                EmptyView()
                            }
                        },
                        isActive: $showEditor
                    ) {
                        EmptyView()
                    }
                    
                    Spacer()
                }
            }
        }
    }
}
