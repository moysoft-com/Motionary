import Foundation

struct Project: Identifiable, Codable {
    let id: UUID
    var name: String
    var creationDate: Date
    var mediaPaths: [String] = [] // Pfade zu importierten Medien

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.creationDate = Date()
    }
}