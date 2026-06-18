// Legacy persisted clip representation retained for project migration.

import Foundation

/// Version-one clip data decoded only by the legacy project migration path.
struct Clip: Identifiable, Codable, Equatable {
    let id: UUID
    var sourceURL: URL
    var startTime: Double
    var endTime: Double
    var mediaType: ClipMediaType

    init(id: UUID = UUID(), sourceURL: URL, startTime: Double, endTime: Double, mediaType: ClipMediaType = .video) {
        self.id = id
        self.sourceURL = sourceURL
        self.startTime = startTime
        self.endTime = endTime
        self.mediaType = mediaType
    }
}
