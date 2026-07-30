// Media import, layer management, and timeline selection behavior.

import Foundation
import PhotosUI
import SwiftUI

extension EditorViewModel {
    func importPhotosItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, !isPerformingLongTask else { return }
        isImporting = true
        importTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isImporting = false
                importTask = nil
            }

            var importedByIndex: [Int: ImportedMedia] = [:]
            var failures: [String] = []

            for batchStart in stride(from: 0, to: items.count, by: 3) {
                guard !Task.isCancelled else { return }
                let batchEnd = min(batchStart + 3, items.count)
                let batch = Array(items[batchStart..<batchEnd].enumerated())
                await withTaskGroup(of: (Int, Result<ImportedMedia, Error>).self) { group in
                    for (offset, item) in batch {
                        let index = batchStart + offset
                        group.addTask {
                            [
                                importService = self.importService,
                                projectID = self.projectID,
                                projectStore = self.projectStore
                            ] in
                            do {
                                let imported = try await importService.importPhotosItem(
                                    item,
                                    projectID: projectID,
                                    projectStore: projectStore
                                )
                                return (index, .success(imported))
                            } catch {
                                return (index, .failure(error))
                            }
                        }
                    }

                    for await (index, result) in group {
                        switch result {
                        case .success(let imported):
                            importedByIndex[index] = imported
                        case .failure(let error):
                            if !(error is CancellationError) {
                                failures.append(error.localizedDescription)
                            }
                        }
                    }
                }
            }

            let orderedImports = importedByIndex.keys.sorted().compactMap { importedByIndex[$0] }
            addImportedMediaBatch(orderedImports, sequentialVisual: items.count > 1)

            if !failures.isEmpty {
                errorMessage =
                    failures.count == 1
                    ? failures[0]
                    : "\(failures.count) media items could not be imported."
            }
        }
    }

    func replaceSelectedMedia(with item: PhotosPickerItem) {
        guard let selectedClipID, selectedClip?.mediaType != .audio, !isPerformingLongTask else { return }
        isImporting = true
        importTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isImporting = false
                importTask = nil
            }
            do {
                let imported = try await importService.importPhotosItem(
                    item,
                    projectID: projectID,
                    projectStore: projectStore
                )
                try Task.checkCancellation()
                guard let location = project.clipLocation(id: selectedClipID) else { return }
                let beforeClip = project.tracks[location.track].clips[location.clip]
                let beforeMedia = project.mediaAsset(for: beforeClip)
                let previousDuration = beforeClip.sourceRange.duration
                var afterClip = beforeClip
                afterClip.name = imported.storedURL.deletingPathExtension().lastPathComponent
                afterClip.mediaID = MediaID(rawValue: imported.source.id)
                afterClip.mediaType = imported.source.mediaType
                afterClip.shape = nil
                afterClip.sourceRange = TimeRangeValue(
                    start: 0,
                    duration: imported.source.mediaType == .image
                        ? previousDuration
                        : min(previousDuration, imported.source.originalDuration)
                )
                let afterMedia = MediaAsset(id: afterClip.mediaID, source: imported.source)
                commit(
                    AnyEditorCommand(
                        ReplaceClipMediaCommand(
                            clipID: selectedClipID,
                            beforeClip: beforeClip,
                            beforeMedia: beforeMedia,
                            afterClip: afterClip,
                            afterMedia: afterMedia,
                            invalidation: [.previewFrame, .compositionTopology, .audioMix, .timelineLayout, .userInterface, .persistence]
                        )
                    )
                )
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func addShape(_ kind: ClipShapeKind) {
        guard !isPerformingLongTask else { return }
        let insertionTime = visibleInsertionTime(at: currentTime)
        let shapeDuration = max(duration - insertionTime, 5)
        let before = project
        var after = project
        let trackIndex = after.insertFreshTrack(kind: .shape)
        let mediaID = MediaID()
        let generatedURL = URL(
            string: "motionary-generated://shape/\(mediaID.rawValue.uuidString)"
        )!
        let source = ClipSource(
            url: generatedURL,
            mediaType: .image,
            originalDuration: shapeDuration,
            naturalSize: CGSizeValue(width: 400, height: 400)
        )
        after.registerMedia(from: source, mediaID: mediaID)
        let item = ShapeTimelineItem(
            name: kind.title,
            mediaID: mediaID,
            shape: ClipShape(kind: kind),
            timelineStart: insertionTime,
            sourceRange: TimeRangeValue(start: 0, duration: shapeDuration)
        )
        after.tracks[trackIndex].items.append(.shape(item))
        after.tracks[trackIndex].sortItems()
        selectedTrackID = after.tracks[trackIndex].id
        selectedClipID = item.id
        commit(
            EditorCommandFactory.importMedia(
                before: before,
                after: after,
                invalidation: [
                    .previewFrame,
                    .compositionTopology,
                    .audioMix,
                    .timelineLayout,
                    .userInterface,
                    .persistence,
                ]
            ),
            seekTo: insertionTime
        )
    }

    func addImportedMediaBatch(
        _ importedMedia: [ImportedMedia],
        sequentialVisual: Bool
    ) {
        guard !importedMedia.isEmpty else { return }

        let before = project
        var after = project
        var finalSelection: (clipID: UUID, trackID: UUID, timelineStart: Double)?

        for imported in importedMedia {
            let kind: TrackKind = imported.source.mediaType == .audio ? .audio : .visual
            let hadVisualClips = after.tracks.contains {
                $0.kind == .visual && !$0.clips.isEmpty
            }
            let targetInsertionTime: Double
            if kind == .visual, hadVisualClips, !sequentialVisual {
                targetInsertionTime = visibleInsertionTime(at: currentTime)
            } else {
                targetInsertionTime = insertionTime(for: kind, in: after)
            }
            let trackIndex =
                after.topAvailableTrackIndex(
                    kind: kind,
                    start: targetInsertionTime,
                    duration: imported.source.originalDuration
                )
                ?? after.insertFreshTrack(kind: kind)
            var clip = TimelineClip(
                name: imported.storedURL.deletingPathExtension().lastPathComponent,
                source: imported.source,
                timelineStart: targetInsertionTime,
                sourceRange: TimeRangeValue(
                    start: 0,
                    duration: imported.source.originalDuration
                )
            )
            after.registerClipMedia(&clip, source: imported.source)
            after.tracks[trackIndex].appendLegacyClip(clip)
            if kind == .visual,
                !hadVisualClips,
                let naturalSize = imported.source.naturalSize?.displaySafeSize
            {
                after.renderSettings = RenderSettings(size: naturalSize)
            }
            finalSelection = (clip.id, after.tracks[trackIndex].id, clip.timelineStart)
        }

        after.renumberTracks()
        if let finalSelection {
            selectedTrackID = finalSelection.trackID
            selectedClipID = finalSelection.clipID
        }
        commit(
            EditorCommandFactory.importMedia(
                before: before,
                after: after,
                invalidation: [.previewFrame, .compositionTopology, .audioMix, .timelineLayout, .userInterface, .persistence]
            ),
            seekTo: finalSelection?.timelineStart
        )
    }

    func importAudioFromPhotosItem(_ item: PhotosPickerItem) {
        guard !isPerformingLongTask else { return }
        isImporting = true
        importTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isImporting = false
                importTask = nil
            }
            do {
                let imported = try await importService.importAudioFromPhotosItem(
                    item,
                    projectID: projectID,
                    projectStore: projectStore
                )
                addImportedMedia(imported)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func importAudio(url: URL) {
        guard !isPerformingLongTask else { return }
        isImporting = true
        importTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isImporting = false
                importTask = nil
            }
            do {
                let imported = try await importService.importAudioFile(
                    url, projectID: projectID, projectStore: projectStore)
                addImportedMedia(imported)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func addLayer() {
        let before = project.tracks
        var after = project
        after.tracks.insert(TimelineTrack(name: "Layer", kind: .undefined), at: 0)
        selectedTrackID = after.tracks.first?.id
        commit(
            EditorCommandFactory.trackStructure(
                before: before,
                after: after.tracks,
                invalidation: [.timelineLayout, .userInterface, .persistence]
            ),
            refreshTimeline: true
        )
    }

    func deleteLayer(_ trackID: UUID) {
        guard let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let before = project.tracks
        var after = project
        let removedTrack = after.tracks.remove(at: trackIndex)

        if let selectedClipID,
            removedTrack.items.contains(where: { $0.id == selectedClipID })
        {
            self.selectedClipID = nil
        }

        if selectedTrackID == trackID {
            let replacementIndex = min(trackIndex, max(after.tracks.count - 1, 0))
            selectedTrackID =
                after.tracks.indices.contains(replacementIndex)
                ? after.tracks[replacementIndex].id
                : nil
        }
        commit(
            EditorCommandFactory.trackStructure(
                before: before,
                after: after.tracks,
                invalidation: [.previewFrame, .compositionTopology, .audioMix, .timelineLayout, .userInterface, .persistence]
            )
        )
    }

    func moveTrack(_ trackID: UUID, to proposedIndex: Int) {
        guard let sourceIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let before = project.tracks
        var after = project
        let track = after.tracks[sourceIndex]
        let boundedIndex = min(max(proposedIndex, 0), max(after.tracks.count - 1, 0))
        guard sourceIndex != boundedIndex else { return }

        after.tracks.remove(at: sourceIndex)
        after.tracks.insert(track, at: boundedIndex)
        after.renumberTracks()
        commit(
            EditorCommandFactory.trackStructure(
                before: before,
                after: after.tracks,
                invalidation: [.previewFrame, .compositionTopology, .audioMix, .timelineLayout, .userInterface, .persistence]
            )
        )
    }

    func selectClip(_ clipID: UUID?, trackID: UUID? = nil, revealInPreview: Bool = false) {
        let resolvedTrackID: UUID?
        if let trackID {
            resolvedTrackID = trackID
        } else if let clipID,
            let track = project.tracks.first(where: { $0.items.contains { $0.id == clipID } })
        {
            resolvedTrackID = track.id
        } else {
            resolvedTrackID = nil
        }

        updateSelection(clipID: clipID, trackID: resolvedTrackID)

        if revealInPreview, let clipID, let item = project.item(id: clipID),
            !(currentTime >= item.timelineStart && currentTime < item.timelineEnd)
        {
            let edge = currentTime < item.timelineStart ? item.timelineStart : item.timelineEnd
            let revealedTime = currentTime < item.timelineStart ? edge + clipRevealEpsilon : edge - clipRevealEpsilon
            seek(to: revealedTime, exact: true)
        }
    }

    func selectTimelineItem(_ itemID: UUID?, trackID: UUID? = nil, revealInPreview: Bool = false) {
        selectClip(itemID, trackID: trackID, revealInPreview: revealInPreview)
    }
}
