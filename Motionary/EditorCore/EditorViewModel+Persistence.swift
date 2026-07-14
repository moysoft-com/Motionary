// Imported-media insertion, persistence, mutation history, and selection validation.

import AVFoundation
import Foundation

extension EditorViewModel {
    func addImportedMedia(_ imported: ImportedMedia, sequentialVisual: Bool = false) {
        let before = project
        var after = project
        let kind: TrackKind = imported.source.mediaType == .audio ? .audio : .visual
        let hadVisualClips = after.tracks.contains { $0.kind == .visual && !$0.clips.isEmpty }
        let targetInsertionTime: Double
        if kind == .visual, hadVisualClips, !sequentialVisual {
            targetInsertionTime = currentTime
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
            sourceRange: TimeRangeValue(start: 0, duration: imported.source.originalDuration)
        )
        after.registerClipMedia(&clip, source: imported.source)
        after.tracks[trackIndex].appendLegacyClip(clip)
        if kind == .visual, !hadVisualClips, let naturalSize = imported.source.naturalSize?.displaySafeSize {
            after.renderSettings = RenderSettings(size: naturalSize)
        }
        after.renumberTracks()
        after.synchronizeMediaLibrary()
        selectedTrackID = after.tracks[trackIndex].id
        selectedClipID = clip.id
        commit(
            EditorCommandFactory.importMedia(
                before: before,
                after: after,
                invalidation: [.previewFrame, .compositionTopology, .audioMix, .timelineLayout, .userInterface, .persistence]
            )
        )
    }

    func repairStoredMediaReferences() {
        var repaired = project
        var changed = false

        for (mediaID, asset) in repaired.mediaLibrary {
            let resolved = projectStore.resolvedMediaURL(asset.url, projectID: projectID)
            if resolved != asset.url {
                var source = asset.source
                source.url = resolved
                repaired.updateMediaAsset(mediaID, source: source)
                changed = true
            }
        }

        if changed {
            let before = project
            commit(
                EditorCommandFactory.importMedia(
                    before: before,
                    after: repaired,
                    invalidation: [.previewFrame, .compositionTopology, .audioMix, .persistence]
                ),
                refreshTimeline: true
            )
        }
    }

    func insertionTime(for kind: TrackKind, in project: EditorProject) -> Double {
        switch kind {
        case .undefined:
            return 0
        case .visual:
            let visualDuration =
                project.tracks
                .filter { $0.kind == .visual }
                .flatMap(\.clips)
                .map(\.timelineEnd)
                .max() ?? 0
            return visualDuration
        case .shape, .text:
            return currentTime
        case .audio:
            return min(currentTime, max(project.duration, currentTime))
        }
    }

    func commit(
        _ command: AnyEditorCommand,
        recordHistory: Bool = true,
        persistChanges: Bool = true,
        touchUpdatedAt: Bool = true,
        refreshTimeline: Bool = true,
        seekTo time: Double? = nil
    ) {
        perform(
            command,
            recordHistory: recordHistory,
            persistChanges: persistChanges,
            touchUpdatedAt: touchUpdatedAt,
            refreshTimeline: refreshTimeline
        )
        if let time {
            updateCurrentTime(clampedTimelineTime(time))
        }
    }

    func mutateProject(
        rebuild: Bool = true,
        recordHistory: Bool = true,
        persistChanges: Bool = true,
        touchUpdatedAt: Bool = true,
        refreshTimeline: Bool = true,
        _ mutation: (inout EditorProject) -> Void
    ) {
        if !rebuild, !recordHistory, !persistChanges, !touchUpdatedAt {
            mutation(&project)
            project.renumberTracks()
            project.synchronizeMediaLibrary()
            if refreshTimeline {
                incrementTimelineContentRevision()
            }
            return
        }

        let before = project
        var after = project
        mutation(&after)
        after.renumberTracks()
        after.synchronizeMediaLibrary()
        guard after != before else { return }

        var renderInvalidation = after.renderInvalidation(comparedTo: before)
        if !rebuild {
            renderInvalidation.subtract([.previewFrame, .compositionTopology, .audioMix])
        }
        var invalidation: EditorInvalidation = [.userInterface, .persistence]
        invalidation.formUnion(renderInvalidation)
        if refreshTimeline {
            invalidation.insert(.timelineLayout)
        }

        perform(
            after.historyCommand(from: before, invalidation: invalidation),
            recordHistory: recordHistory,
            persistChanges: persistChanges,
            touchUpdatedAt: touchUpdatedAt,
            refreshTimeline: refreshTimeline
        )
    }

    func perform(
        _ command: AnyEditorCommand,
        recordHistory: Bool = true,
        persistChanges: Bool = true,
        touchUpdatedAt: Bool = true,
        refreshTimeline: Bool = true
    ) {
        command.apply(to: &project)
        if command.invalidation.contains(.persistence) || command.invalidation.contains(.compositionTopology) {
            project.synchronizeMediaLibrary()
        }
        project.renumberTracks()
        updateCurrentTime(clampedTimelineTime(currentTime))
        if refreshTimeline {
            incrementTimelineContentRevision()
            timelineClipCacheRevision = -1
            timelineSnapshotToken = (-1, nil)
        }
        if recordHistory {
            undoStack.append(command)
            if undoStack.count > 80 {
                undoStack.removeFirst()
            }
            redoStack.removeAll()
            updateHistoryFlags()
        }
        if touchUpdatedAt {
            project.updatedAt = Date()
        }
        if persistChanges {
            persist()
        }
        if !command.invalidation.intersection([.previewFrame, .compositionTopology, .audioMix]).isEmpty {
            schedulePreviewRebuild(seekTo: currentTime, invalidation: command.invalidation)
        }
    }

    func schedulePreviewRebuild(
        seekTo time: Double? = nil,
        delay: Bool = true,
        invalidation: EditorInvalidation = [.previewFrame]
    ) {
        if isScrubbing {
            deferredPreviewInvalidation.formUnion(invalidation)
            return
        }

        rebuildTask?.cancel()
        previewGeneration &+= 1
        let generation = previewGeneration
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            if delay {
                try? await Task.sleep(nanoseconds: 160_000_000)
            }
            guard !Task.isCancelled, !self.isScrubbing else { return }
            await self.rebuildPreview(
                seekTo: time,
                invalidation: invalidation,
                generation: generation
            )
        }
    }

    func persist() {
        autosaveTask?.cancel()
        let snapshot = project
        let projectID = projectID
        projectSession.saveState = .saving
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self else { return }
                try await self.projectStore.repository.save(
                    ProjectContent(editorProject: snapshot),
                    projectID: projectID
                )
                guard !Task.isCancelled else { return }
                self.projectStore.recordSavedContent(
                    ProjectContent(editorProject: snapshot),
                    projectID: projectID
                )
                self.projectSession.saveState = .saved(Date())
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                let message = error.localizedDescription
                self.projectSession.saveState = .failed(message)
                self.errorMessage = message
                AppLogger.persistence.error(
                    "Failed to autosave project content: \(message, privacy: .public)"
                )
            }
        }
    }

    func installTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }

        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                let seconds = CMTimeGetSeconds(time)
                if !self.isScrubbing {
                    self.updateCurrentTime(self.clampedTimelineTime(seconds))
                }
                if self.isPlaying, self.duration > 0, seconds >= self.lastPlayableTime {
                    self.player?.pause()
                    self.isPlaying = false
                    self.seekPlayer(to: self.lastPlayableTime, exact: true)
                }
                if let graphSegment = self.graphSegment,
                    let clip = self.project.clip(id: graphSegment.clipID)
                {
                    let graphEnd = clip.timelineStart + graphSegment.endTime
                    if seconds >= graphEnd - 0.012 {
                        self.player?.pause()
                        self.isPlaying = false
                        self.seek(to: graphEnd)
                    }
                }
            }
        }
    }

    func updateHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func updateCurrentTime(_ time: Double) {
        currentTime = clampedTimelineTime(time)
    }

    func updateSelection(clipID: UUID?, trackID: UUID?) {
        selectedClipID = clipID
        selectedTrackID = trackID
    }

    func isTimeInside(_ clip: TimelineClip) -> Bool {
        currentTime >= clip.timelineStart && currentTime < clip.timelineEnd
    }

    func nearestVisibleTime(for clip: TimelineClip) -> Double {
        let epsilon = min(max(clip.sourceRange.duration * 0.05, 0.001), clipRevealEpsilon)
        if currentTime < clip.timelineStart {
            return min(clip.timelineStart + epsilon, max(clip.timelineStart, clip.timelineEnd - epsilon))
        }
        return max(clip.timelineStart, clip.timelineEnd - epsilon)
    }

    func incrementTimelineContentRevision() {
        timelineContentRevision &+= 1
    }

    func setPreviewQualityForInteraction(_ interactive: Bool) {
        previewQuality = interactive ? .interactive : .balanced
    }
}
