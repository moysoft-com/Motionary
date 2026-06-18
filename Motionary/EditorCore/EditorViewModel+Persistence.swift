// Imported-media insertion, persistence, mutation history, and selection validation.

import AVFoundation
import Foundation

extension EditorViewModel {
    func addImportedMedia(_ imported: ImportedMedia, sequentialVisual: Bool = false) {
        mutateProject { project in
            let kind: TrackKind = imported.source.mediaType == .audio ? .audio : .visual
            let hadVisualClips = project.tracks.contains { $0.kind == .visual && !$0.clips.isEmpty }
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
                sourceRange: TimeRangeValue(start: 0, duration: imported.source.originalDuration)
            )
            project.tracks[trackIndex].clips.append(clip)
            project.tracks[trackIndex].clips.sort { $0.timelineStart < $1.timelineStart }
            if kind == .visual, !hadVisualClips, let naturalSize = imported.source.naturalSize?.displaySafeSize {
                project.renderSettings = RenderSettings(size: naturalSize)
            }
            project.renumberTracks()
            selectedTrackID = project.tracks[trackIndex].id
            selectedClipID = clip.id
        }
    }

    func repairStoredMediaReferences() {
        var repaired = project
        var changed = false

        for trackIndex in repaired.tracks.indices {
            for clipIndex in repaired.tracks[trackIndex].clips.indices {
                let url = repaired.tracks[trackIndex].clips[clipIndex].source.url
                let resolved = projectStore.resolvedMediaURL(url, projectID: projectID)
                if resolved != url {
                    repaired.tracks[trackIndex].clips[clipIndex].source.url = resolved
                    changed = true
                }
            }
        }

        if changed {
            project = repaired
            incrementTimelineContentRevision()
            persist()
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
        case .audio:
            return min(currentTime, max(project.duration, currentTime))
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
        let previous = project
        mutation(&project)
        project.renumberTracks()
        guard project != previous else { return }
        if refreshTimeline {
            incrementTimelineContentRevision()
        }
        if recordHistory {
            undoStack.append(previous)
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
        if rebuild {
            schedulePreviewRebuild(seekTo: currentTime)
        }
    }

    func schedulePreviewRebuild(seekTo time: Double? = nil, delay: Bool = true) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            if delay {
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
            guard !Task.isCancelled else { return }
            await self.rebuildPreview(seekTo: time)
        }
    }

    func persist() {
        projectStore.saveContent(ProjectContent(editorProject: project), for: projectID)
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
                    self.updateCurrentTime(min(max(seconds, 0), max(self.duration, 0)))
                }
                if self.duration > 0, seconds >= self.duration - 0.04 {
                    self.player?.pause()
                    self.isPlaying = false
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
        currentTime = time
    }

    func updateSelection(clipID: UUID?, trackID: UUID?) {
        let changed = selectedClipID != clipID || selectedTrackID != trackID
        selectedClipID = clipID
        selectedTrackID = trackID
        if changed {
            incrementTimelineContentRevision()
        }
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
}
