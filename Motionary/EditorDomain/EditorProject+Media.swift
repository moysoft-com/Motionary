// Project-level media resolution for timeline clips.

import Foundation

struct ClipMediaDescriptor: Equatable, Sendable {
    let mediaID: MediaID
    let url: URL
    let mediaType: ClipMediaType
    let originalDuration: Double
    let naturalSize: CGSizeValue?

    init(asset: MediaAsset) {
        mediaID = asset.id
        url = asset.url
        mediaType = asset.mediaType
        originalDuration = asset.originalDuration
        naturalSize = asset.naturalSize
    }
}

extension EditorProject {
    func mediaAsset(for clip: TimelineClip) -> MediaAsset? {
        mediaLibrary[clip.mediaID]
    }

    func mediaDescriptor(for clip: TimelineClip) -> ClipMediaDescriptor? {
        mediaAsset(for: clip).map(ClipMediaDescriptor.init(asset:))
    }

    func mediaURL(for clip: TimelineClip) -> URL {
        mediaAsset(for: clip)?.url ?? URL(fileURLWithPath: "/dev/null")
    }

    func originalDuration(for clip: TimelineClip) -> Double {
        mediaAsset(for: clip)?.originalDuration ?? 0
    }

    func naturalSize(for clip: TimelineClip) -> CGSizeValue? {
        mediaAsset(for: clip)?.naturalSize
    }

    @discardableResult
    mutating func registerMedia(
        from source: ClipSource,
        mediaID: MediaID? = nil
    ) -> MediaID {
        let id = mediaID ?? MediaID(rawValue: source.id)
        mediaLibrary[id] = MediaAsset(id: id, source: source)
        return id
    }

    mutating func registerClipMedia(_ clip: inout TimelineClip, source: ClipSource) {
        let mediaID = registerMedia(from: source, mediaID: clip.mediaID)
        clip.mediaID = mediaID
        clip.mediaType = source.mediaType
    }
}
