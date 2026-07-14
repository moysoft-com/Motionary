// Text-item creation and editing through the shared editor mutation gateway.

import Foundation

extension EditorViewModel {
    var selectedTextItem: TextTimelineItem? {
        guard case .text(let item) = selectedTimelineItem else { return nil }
        return item
    }

    @discardableResult
    func addText() -> UUID? {
        guard !isImporting else { return nil }

        let insertionTime = min(max(currentTime, 0), max(duration, currentTime))
        let remainingDuration = max(duration - insertionTime, 0)
        let textDuration = remainingDuration >= 0.1 ? min(remainingDuration, 5) : 5
        var insertedItemID: UUID?
        var insertedTrackID: UUID?

        mutateProject { project in
            let trackIndex =
                project.topAvailableTrackIndex(
                    kind: .text,
                    start: insertionTime,
                    duration: textDuration
                )
                ?? project.insertFreshTrack(kind: .text)
            let item = project.appendTextItem(
                "Text",
                at: insertionTime,
                duration: textDuration,
                trackIndex: trackIndex
            )
            insertedItemID = item.id
            insertedTrackID = project.tracks[trackIndex].id
        }

        guard let insertedItemID else { return nil }
        selectTimelineItem(insertedItemID, trackID: insertedTrackID, revealInPreview: true)
        return insertedItemID
    }

    func updateSelectedText(
        interactive: Bool = false,
        _ update: @escaping (inout TextTimelineItem) -> Void
    ) {
        guard let selectedTimelineItemID else { return }
        updateTextItem(selectedTimelineItemID, interactive: interactive, update)
    }

    func updateTextItem(
        _ itemID: UUID,
        interactive: Bool = false,
        _ update: @escaping (inout TextTimelineItem) -> Void
    ) {
        if interactive {
            beginInteractiveEdit()
        }

        mutateProject(
            rebuild: !interactive,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive,
            refreshTimeline: true
        ) { project in
            guard let location = project.itemLocation(id: itemID),
                case .text(var item) = project.tracks[location.track].items[location.item]
            else { return }
            update(&item)
            item.animations = item.animations.normalized(for: item.duration)
            item.synchronizePropertyAnimationBaseValues()
            project.tracks[location.track].items[location.item] = .text(item)
        }
        liveTextPreviewID = itemID
    }

    func finishTextEditing() {
        finishInteractiveEdit()
    }
}
