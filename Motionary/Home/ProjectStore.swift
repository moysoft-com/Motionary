import Foundation

final class ProjectStore: ObservableObject {
    @Published var projects: [Project] = [] {
        didSet {
            save()
        }
    }

    private let storageURL: URL
    private var isLoading = false

    init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        storageURL = (documentsURL ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("projects.json")
        load()
    }

    func addProject() -> Project {
        let newProject = Project(title: "Project #\(projects.count + 1)")
        projects.append(newProject)
        return newProject
    }

    func deleteProject(with id: UUID) {
        projects.removeAll { $0.id == id }
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        guard let data = try? Data(contentsOf: storageURL) else { return }
        do {
            projects = try JSONDecoder().decode([Project].self, from: data)
        } catch {
            print("Failed to load projects: \(error)")
        }
    }

    private func save() {
        guard !isLoading else { return }
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            print("Failed to save projects: \(error)")
        }
    }
}
