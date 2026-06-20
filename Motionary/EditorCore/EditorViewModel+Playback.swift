// Editor lifecycle, playback, seeking, scrubbing, and undo history.

import AVFoundation

extension EditorViewModel {
    func start() {
        EditorAudioSession.configurePlayback()
        repairStoredMediaReferences()
        schedulePreviewRebuild(seekTo: 0, delay: false)
        persist()
    }

    func stop() {
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
        if !isPlaying && currentTime >= duration {
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
        guard let previous = undoStack.popLast() else { return }
        let retainedClipID = selectedClipID
        redoStack.append(project)
        project = previous
        restoreSelectionIfPossible(retainedClipID)
        incrementTimelineContentRevision()
        updateHistoryFlags()
        persist()
        schedulePreviewRebuild(seekTo: min(currentTime, duration))
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        let retainedClipID = selectedClipID
        undoStack.append(project)
        project = next
        restoreSelectionIfPossible(retainedClipID)
        incrementTimelineContentRevision()
        updateHistoryFlags()
        persist()
        schedulePreviewRebuild(seekTo: min(currentTime, duration))
    }

    func seek(to time: Double, exact: Bool = true) {
        let clamped = min(max(time, 0), max(duration, 0))
        updateCurrentTime(clamped)
        seekPlayer(to: clamped, exact: exact)
    }

    func seekPlayer(to time: Double, exact: Bool) {
        let tolerance = exact ? CMTime.zero : CMTime(seconds: 0.035, preferredTimescale: 600)
        player?.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    func beginScrub() {
        wasPlayingBeforeScrub = isPlaying
        player?.pause()
        isPlaying = false
        isScrubbing = true
    }

    func updateScrub(to time: Double) {
        let clamped = min(max(time, 0), max(duration, 0))
        updateCurrentTime(clamped)
        pendingScrubSeekTime = clamped
        guard scrubSeekTask == nil else { return }

        scrubSeekTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 35_000_000)
            await MainActor.run {
                guard let self else { return }
                let target = self.pendingScrubSeekTime
                self.pendingScrubSeekTime = nil
                self.scrubSeekTask = nil
                guard let target else { return }
                self.seekPlayer(to: target, exact: false)
            }
        }
    }

    func endScrub(at time: Double) {
        scrubSeekTask?.cancel()
        scrubSeekTask = nil
        pendingScrubSeekTime = nil
        seek(to: time, exact: true)
        isScrubbing = false
        wasPlayingBeforeScrub = false
    }

    var navigationPoints: [Double] {
        let points: [Double]
        if let clip = selectedClip {
            points =
                [clip.timelineStart, clip.timelineEnd]
                + clip.allKeyframeTimes.map { clip.timelineStart + $0 }
        } else {
            points = project.tracks.flatMap(\.clips).flatMap {
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
            let location = project.clipLocation(id: clipID)
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
