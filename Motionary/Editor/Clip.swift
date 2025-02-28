import Foundation

struct Clip: Identifiable, Equatable, Codable {
    let id: UUID
    var start: Double
    var end: Double

    init(start: Double, end: Double) {
        self.id = UUID()
        self.start = start
        self.end = end
    }
}