import Foundation

final class ProjectStore: ObservableObject {
    @Published var projects: [Project] = [] {
        didSet {
            save()
        }
    }

    private let storageKey = "savedProjects"

    init() {
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
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        do {
            projects = try JSONDecoder().decode([Project].self, from: data)
        } catch {
            print("Failed to load projects: \(error)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(projects)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            print("Failed to save projects: \(error)")
        }
    }
}
