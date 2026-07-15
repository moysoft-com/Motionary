// Typed timeline item helpers for compound sequences, text, and static speed.

import Foundation

extension EditorProject {
    func item(id: UUID) -> TimelineItem? {
        tracks.lazy.flatMap(\.items).first { $0.id == id }
    }

    func itemLocation(id: UUID) -> (track: Int, item: Int)? {
        for trackIndex in tracks.indices {
            if let itemIndex = tracks[trackIndex].itemIndex(id: id) {
                return (trackIndex, itemIndex)
            }
        }
        return nil
    }

    mutating func replaceItem(id: UUID, with item: TimelineItem) {
        guard let location = itemLocation(id: id) else { return }
        tracks[location.track].items[location.item] = item
        synchronizeMediaLibrary()
    }

    mutating func appendTextItem(
        _ text: String,
        at timelineStart: Double,
        duration: Double = 5,
        style: TextStyle = TextStyle(),
        trackIndex: Int? = nil
    ) -> TextTimelineItem {
        let item = TextTimelineItem(
            text: text,
            style: style,
            timelineStart: timelineStart,
            duration: duration
        )
        let destinationIndex: Int
        if let trackIndex,
            tracks.indices.contains(trackIndex),
            tracks[trackIndex].canAcceptClipKind(.text)
        {
            destinationIndex = trackIndex
        } else if let existing = tracks.firstIndex(where: { $0.canAcceptClipKind(.text) }) {
            destinationIndex = existing
        } else {
            destinationIndex = insertFreshTrack(kind: .text)
        }
        tracks[destinationIndex].items.append(.text(item))
        tracks[destinationIndex].sortItems()
        return item
    }

    mutating func appendCompoundItem(
        name: String,
        nestedTracks: [TimelineTrack],
        at timelineStart: Double,
        duration: Double,
        trackIndex: Int? = nil
    ) -> CompoundTimelineItem {
        let sequence = CompoundSequence(name: name, tracks: nestedTracks)
        sequences[sequence.id] = sequence
        let item = CompoundTimelineItem(
            name: name,
            sequenceID: sequence.id,
            timelineStart: timelineStart,
            duration: duration
        )
        let destinationIndex: Int
        if let trackIndex, tracks.indices.contains(trackIndex) {
            destinationIndex = trackIndex
        } else if let existing = tracks.firstIndex(where: { $0.canAcceptClipKind(.visual) }) {
            destinationIndex = existing
        } else {
            destinationIndex = insertFreshTrack(kind: .visual)
        }
        tracks[destinationIndex].items.append(.compound(item))
        tracks[destinationIndex].sortItems()
        return item
    }

    mutating func setSpeedMap(for itemID: UUID, speedMap: SpeedMap) {
        guard let location = itemLocation(id: itemID) else { return }
        guard case .media(var item) = tracks[location.track].items[location.item] else { return }
        item.speedMap = item.mediaType == .video || item.mediaType == .audio
            ? .constant(speed: speedMap.speed(at: 0))
            : .constant
        tracks[location.track].items[location.item] = .media(item)
    }

    func flattenedRenderableItems() -> [TimelineItem] {
        var result: [TimelineItem] = []
        for track in tracks {
            for item in track.items {
                switch item {
                case .compound(let compound):
                    if let sequence = sequences[compound.sequenceID] {
                        for nestedTrack in sequence.tracks {
                            for nestedItem in nestedTrack.items {
                                var offset = nestedItem
                                offset.timelineStart = compound.timelineStart + nestedItem.timelineStart
                                result.append(offset)
                            }
                        }
                    }
                default:
                    result.append(item)
                }
            }
        }
        return result
    }
}
