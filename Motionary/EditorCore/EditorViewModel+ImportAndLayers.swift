// Media import, layer management, and timeline selection behavior.

import Foundation
import PhotosUI
import SwiftUI

extension EditorViewModel {
    func importPhotosItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, !isImporting else { return }
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
        guard let selectedClipID, selectedClip?.mediaType != .audio, !isImporting else { return }
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
                mutateProject { project in
                    guard let location = project.clipLocation(id: selectedClipID) else { return }
                    var clip = project.tracks[location.track].clips[location.clip]
                    let previousDuration = clip.sourceRange.duration
                    clip.name = imported.storedURL.deletingPathExtension().lastPathComponent
                    clip.source = imported.source
                    clip.shape = nil
                    clip.sourceRange = TimeRangeValue(
                        start: 0,
                        duration: imported.source.mediaType == .image
                            ? previousDuration
                            : min(previousDuration, imported.source.originalDuration)
                    )
                    project.tracks[location.track].clips[location.clip] = clip
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func addShape(_ kind: ClipShapeKind) {
        guard !isImporting else { return }
        isImporting = true
        importTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isImporting = false
                importTask = nil
            }
            do {
                let shapeDuration = max(duration - currentTime, 5)
                let imported = try await importService.makeShapeMedia(
                    duration: shapeDuration,
                    canvasSize: project.renderSettings.size,
                    projectID: projectID,
                    projectStore: projectStore
                )
                try Task.checkCancellation()
                mutateProject { project in
                    let trackIndex = project.insertFreshTrack(kind: .shape)
                    var source = imported.source
                    source.naturalSize = CGSizeValue(width: 400, height: 400)
                    let clip = TimelineClip(
                        name: kind.title,
                        source: source,
                        timelineStart: self.currentTime,
                        sourceRange: TimeRangeValue(start: 0, duration: shapeDuration),
                        shape: ClipShape(kind: kind)
                    )
                    project.tracks[trackIndex].clips.append(clip)
                    project.tracks[trackIndex].clips.sort { $0.timelineStart < $1.timelineStart }
                    self.selectedTrackID = project.tracks[trackIndex].id
                    self.selectedClipID = clip.id
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func addImportedMediaBatch(
        _ importedMedia: [ImportedMedia],
        sequentialVisual: Bool
    ) {
        guard !importedMedia.isEmpty else { return }

        mutateProject { project in
            var finalSelection: (clipID: UUID, trackID: UUID)?

            for imported in importedMedia {
                let kind: TrackKind = imported.source.mediaType == .audio ? .audio : .visual
                let hadVisualClips = project.tracks.contains {
                    $0.kind == .visual && !$0.clips.isEmpty
                }
                let trackIndex = project.insertFreshTrack(kind: kind)
                let targetInsertionTime: Double
                if kind == .visual, hadVisualClips, !sequentialVisual {
                    targetInsertionTime = currentTime
                } else {
                    targetInsertionTime = insertionTime(for: kind, in: project)
                }
                let clip = TimelineClip(
                    name: imported.storedURL.deletingPathExtension().lastPathComponent,
                    source: imported.source,
                    timelineStart: targetInsertionTime,
                    sourceRange: TimeRangeValue(
                        start: 0,
                        duration: imported.source.originalDuration
                    )
                )
                project.tracks[trackIndex].clips.append(clip)
                project.tracks[trackIndex].clips.sort { $0.timelineStart < $1.timelineStart }
                if kind == .visual,
                    !hadVisualClips,
                    let naturalSize = imported.source.naturalSize?.displaySafeSize
                {
                    project.renderSettings = RenderSettings(size: naturalSize)
                }
                finalSelection = (clip.id, project.tracks[trackIndex].id)
            }

            project.renumberTracks()
            if let finalSelection {
                selectedTrackID = finalSelection.trackID
                selectedClipID = finalSelection.clipID
            }
        }
    }

    func importAudioFromPhotosItem(_ item: PhotosPickerItem) {
        guard !isImporting else { return }
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
        guard !isImporting else { return }
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
        mutateProject(rebuild: false) { project in
            project.tracks.insert(TimelineTrack(name: "Layer", kind: .undefined), at: 0)
            selectedTrackID = project.tracks.first?.id
        }
    }

    func deleteLayer(_ trackID: UUID) {
        mutateProject { project in
            guard let trackIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            let removedTrack = project.tracks.remove(at: trackIndex)

            if let selectedClipID,
                removedTrack.clips.contains(where: { $0.id == selectedClipID })
            {
                self.selectedClipID = nil
            }

            if selectedTrackID == trackID {
                let replacementIndex = min(trackIndex, max(project.tracks.count - 1, 0))
                selectedTrackID =
                    project.tracks.indices.contains(replacementIndex)
                    ? project.tracks[replacementIndex].id
                    : nil
            }
        }
    }

    func moveTrack(_ trackID: UUID, to proposedIndex: Int) {
        mutateProject(rebuild: false) { project in
            guard let sourceIndex = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            let track = project.tracks[sourceIndex]
            let boundedIndex = min(max(proposedIndex, 0), max(project.tracks.count - 1, 0))
            guard sourceIndex != boundedIndex else { return }

            project.tracks.remove(at: sourceIndex)
            project.tracks.insert(track, at: boundedIndex)
            project.renumberTracks()
        }
    }

    func selectClip(_ clipID: UUID?, trackID: UUID? = nil, revealInPreview: Bool = false) {
        let resolvedTrackID: UUID?
        if let trackID {
            resolvedTrackID = trackID
        } else if let clipID,
            let track = project.tracks.first(where: { $0.clips.contains { $0.id == clipID } })
        {
            resolvedTrackID = track.id
        } else {
            resolvedTrackID = nil
        }

        updateSelection(clipID: clipID, trackID: resolvedTrackID)

        if revealInPreview, let clipID, let clip = project.clip(id: clipID), !isTimeInside(clip) {
            seek(to: nearestVisibleTime(for: clip), exact: true)
        }
    }
}
