// Typed timeline item helpers for compound sequences, text, and speed.

import Foundation

struct AdjustmentGroupInput: Identifiable {
    let track: TimelineTrack
    var memberIDs: Set<UUID>
    var isGroup = false
    var sourceCount = 1
    var id: UUID { track.id }
}

extension EditorProject {
    /// The actual isolated inputs available below an adjustment at the playhead.
    /// Earlier adjustments become atomic group inputs, matching the compositor.
    func adjustmentGroupInputs(for itemID: UUID, at time: Double) -> [AdjustmentGroupInput] {
        guard let location = itemLocation(id: itemID) else { return [] }
        var inputs: [AdjustmentGroupInput] = []
        for track in tracks.dropFirst(location.track + 1).reversed() where !track.isMuted {
            guard track.kind == .visual || track.kind == .shape || track.kind == .text else { continue }
            for item in track.items.sorted(by: { $0.timelineStart < $1.timelineStart })
                where item.timelineStart <= time && item.timelineEnd > time {
                if case .adjustment(let adjustment) = item {
                    guard adjustment.visuals.transform.opacity.value(at: max(time - item.timelineStart, 0)) > 0.000_001 else { continue }
                    func matches(_ input: AdjustmentGroupInput) -> Bool {
                        switch adjustment.targets.mode {
                        case .all: true
                        case .selected: !input.memberIDs.isDisjoint(with: adjustment.targets.trackIDs)
                        case .excluding: input.memberIDs.isDisjoint(with: adjustment.targets.trackIDs)
                        }
                    }
                    let selected = inputs.filter(matches)
                    guard !selected.isEmpty || adjustment.targets.mode == .all else { continue }
                    let insertion = inputs.lastIndex(where: matches).map { anchor in
                        inputs.prefix(anchor).filter { !matches($0) }.count
                    } ?? inputs.count
                    var members = selected.reduce(into: Set<UUID>()) { $0.formUnion($1.memberIDs) }
                    members.insert(track.id)
                    inputs.removeAll(where: matches)
                    inputs.insert(AdjustmentGroupInput(track: track, memberIDs: members, isGroup: true, sourceCount: selected.reduce(0) { $0 + $1.sourceCount }), at: insertion)
                } else if item.editableVisuals != nil {
                    if !inputs.contains(where: { $0.id == track.id }) {
                        inputs.append(AdjustmentGroupInput(track: track, memberIDs: [track.id]))
                    }
                }
            }
        }
        return inputs.reversed()
    }

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
        let timelineItem = TimelineItem.compound(item)
        let destinationIndex: Int
        if let trackIndex,
            tracks.indices.contains(trackIndex),
            tracks[trackIndex].canAcceptItem(timelineItem)
        {
            destinationIndex = trackIndex
        } else if let existing = tracks.firstIndex(where: { $0.canAcceptItem(timelineItem) }) {
            destinationIndex = existing
        } else {
            destinationIndex = insertFreshTrack(kind: .visual)
        }
        tracks[destinationIndex].items.append(timelineItem)
        tracks[destinationIndex].sortItems()
        return item
    }

    mutating func setSpeedMap(for itemID: UUID, speedMap: SpeedMap) {
        guard let location = itemLocation(id: itemID) else { return }
        guard case .media(var item) = tracks[location.track].items[location.item] else { return }
        item.speedMap = speedMap.rebased(from: 0, duration: item.sourceRange.duration)
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
