// Editor lifecycle, playback, seeking, scrubbing, and undo history.

import AVFoundation

extension EditorViewModel {
    func start() {
        EditorAudioSession.configurePlayback()
        TimelineCacheLifecycle.installMemoryWarningHandler()
        Task {
            await TimelineThumbnailTileCache.shared.setActiveProject(projectID)
        }
        repairStoredMediaReferences()
        schedulePreviewRebuild(
            seekTo: 0,
            delay: false,
            invalidation: [.previewFrame, .compositionTopology, .audioMix]
        )
        persist()
    }

    func stop() {
        let content = ProjectContent(editorProject: project)
        autosaveTask?.cancel()
        autosaveTask = Task { [projectStore, projectID] in
            try? await projectStore.repository.save(content, projectID: projectID)
        }
        Task {
            await TimelineThumbnailTileCache.shared.removeAll()
            await TimelineAudioWaveformCache.shared.removeAll()
            await MediaAssetCache.shared.removeAll()
        }
        rebuildTask?.cancel()
        rebuildTask = nil
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        importTask?.cancel()
        importTask = nil
        exportTask?.cancel()
        exportTask = nil
        isImporting = false
        isExporting = false
        pendingScrubSeekTime = nil
        scrubSessionGeneration &+= 1
        lastScrubUIUpdate = 0
        isRenderingPreview = false
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player?.pause()
        player = nil
        isPlaying = false
    }

    func cancelLongRunningTask() {
        if isExporting {
            exportTask?.cancel()
            exportTask = nil
            isExporting = false
            return
        }
        if isImporting {
            importTask?.cancel()
            importTask = nil
            isImporting = false
            return
        }
        if isRenderingPreview {
            rebuildTask?.cancel()
            rebuildTask = nil
            isRenderingPreview = false
        }
    }

    func togglePlayback() {
        guard let player else { return }
        let endTolerance = max(keyframeTimeTolerance, 0.05)
        if !isPlaying, duration > 0, currentTime >= max(duration - endTolerance, 0) {
            seek(to: 0)
        }

        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func toggleGraphPlayback() {
        guard let segment = graphSegment,
            let clip = project.clip(id: segment.clipID)
        else {
            togglePlayback()
            return
        }
        let start = clip.timelineStart + segment.startTime
        let end = clip.timelineStart + segment.endTime
        if !isPlaying, currentTime >= end - keyframeTimeTolerance {
            seek(to: start)
        }
        togglePlayback()
    }

    func undo() {
        guard let command = undoStack.popLast() else { return }
        let retainedClipID = selectedClipID
        command.undo(on: &project)
        redoStack.append(command)
        restoreSelectionIfPossible(retainedClipID)
        incrementTimelineContentRevision()
        updateHistoryFlags()
        persist()
        schedulePreviewRebuild(
            seekTo: clampedTimelineTime(currentTime),
            invalidation: command.invalidation
        )
    }

    func redo() {
        guard let command = redoStack.popLast() else { return }
        let retainedClipID = selectedClipID
        command.apply(to: &project)
        undoStack.append(command)
        restoreSelectionIfPossible(retainedClipID)
        incrementTimelineContentRevision()
        updateHistoryFlags()
        persist()
        schedulePreviewRebuild(
            seekTo: clampedTimelineTime(currentTime),
            invalidation: command.invalidation
        )
    }

    func seek(to time: Double, exact: Bool = true) {
        let clamped = clampedTimelineTime(time)
        updateCurrentTime(clamped)
        seekPlayer(to: clamped, exact: exact)
    }

    func seekPlayer(to time: Double, exact: Bool) {
        let clamped = clampedTimelineTime(time)
        let tolerance = exact ? CMTime.zero : CMTime(seconds: 0.035, preferredTimescale: 600)
        player?.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    func beginScrub() {
        guard !isScrubbing else { return }
        scrubSessionGeneration &+= 1
        wasPlayingBeforeScrub = isPlaying
        player?.pause()
        isPlaying = false
        isScrubbing = true
        rebuildTask?.cancel()
        rebuildTask = nil
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        pendingScrubSeekTime = nil
        lastScrubUIUpdate = 0
        previewQuality = .interactive
    }

    func endScrub(at time: Double) {
        let clamped = clampedTimelineTime(time)
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        pendingScrubSeekTime = nil
        lastScrubUIUpdate = 0
        scrubSessionGeneration &+= 1
        let generation = scrubSessionGeneration
        player?.currentItem?.cancelPendingSeeks()
        updateCurrentTime(clamped)
        previewQuality = .balanced

        guard let player else {
            finishScrub(at: clamped, generation: generation)
            return
        }
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                self?.finishScrub(at: clamped, generation: generation)
            }
        }
    }

    private func finishScrub(at time: Double, generation: Int) {
        guard generation == scrubSessionGeneration, isScrubbing else { return }
        updateCurrentTime(time)
        isScrubbing = false
        wasPlayingBeforeScrub = false
        flushDeferredPreviewRebuild(seekTo: time)
    }

    var navigationPoints: [Double] {
        let points: [Double]
        if let clip = selectedClip {
            points =
                [clip.timelineStart, clip.timelineEnd]
                + clip.allKeyframeTimes.map { clip.timelineStart + $0 }
        } else {
            points = project.tracks.flatMap(\.items).flatMap {
                [$0.timelineStart, $0.timelineEnd]
            }
        }
        return points.sorted().reduce(into: [Double]()) { result, value in
            if result.last.map({ abs($0 - value) > keyframeTimeTolerance }) ?? true {
                result.append(value)
            }
        }
    }

    var canNavigateBackward: Bool {
        navigationPoints.contains { $0 < currentTime - keyframeTimeTolerance }
    }

    var canNavigateForward: Bool {
        navigationPoints.contains { $0 > currentTime + keyframeTimeTolerance }
    }

    func navigateBackward() {
        guard let target = navigationPoints.last(
            where: { $0 < currentTime - keyframeTimeTolerance }
        ) else { return }
        seek(to: target)
    }

    func navigateForward() {
        guard let target = navigationPoints.first(
            where: { $0 > currentTime + keyframeTimeTolerance }
        ) else { return }
        seek(to: target)
    }

    private func restoreSelectionIfPossible(_ clipID: UUID?) {
        if let clipID,
            let location = project.itemLocation(id: clipID)
        {
            selectedClipID = clipID
            selectedTrackID = project.tracks[location.track].id
        } else {
            selectedClipID = nil
            selectedTrackID =
                project.tracks.first(where: { $0.kind == .visual })?.id
                ?? project.tracks.first?.id
            graphSegment = nil
        }
    }
}
