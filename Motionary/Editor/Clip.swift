import Foundation

struct Clip: Identifiable, Equatable {
    let id = UUID()
    var sourceURL: URL
    var startTime: Double   // Startzeit in Sekunden
    var endTime: Double     // Endzeit in Sekunden
}