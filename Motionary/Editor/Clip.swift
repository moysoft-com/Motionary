import Foundation

struct Clip: Identifiable, Codable, Equatable {
    let id: UUID
    var sourceURL: URL
    var startTime: Double   // Startzeit in Sekunden
    var endTime: Double     // Endzeit in Sekunden
    var mediaType: ClipMediaType

    init(id: UUID = UUID(), sourceURL: URL, startTime: Double, endTime: Double, mediaType: ClipMediaType = .video) {
        self.id = id
        self.sourceURL = sourceURL
        self.startTime = startTime
        self.endTime = endTime
        self.mediaType = mediaType
    }
}
