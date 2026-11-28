import Foundation

extension EditorViewModel {
    func prepareSmoothMotion(for itemID: UUID, mode: SmoothMotionMode) {
        guard !isPerformingLongTask, analysisTask == nil, exportTask == nil,
            let location = project.itemLocation(id: itemID),
            !project.tracks[location.track].isLocked,
            case .media(let item) = project.tracks[location.track].items[location.item],
            item.canUseSmoothMotion,
            let source = project.mediaLibrary[item.mediaID]?.url
        else { return }

        finishInteractiveEdit()
        pausePlaybackForEditing()
        let frameRate = project.renderSettings.frameRate
        let recipe = item.smoothMotionRecipe(frameRate: frameRate, mode: mode)
        let jobID = UUID()
        smoothMotionJobID = jobID
        analysisState = EditorAnalysisState(kind: .smoothMotion, progress: 0)
        analysisTask = Task { [weak self] in
            defer {
                if let self, self.smoothMotionJobID == jobID {
                    self.smoothMotionJobID = nil
                    self.analysisState = nil
                    self.analysisTask = nil
                }
            }
            do {
                _ = try await SmoothMotion.prepare(source: source, recipe: recipe) { [weak self] progress in
                    await self?.updateSmoothMotionProgress(progress, jobID: jobID)
                }
                try Task.checkCancellation()
                guard let self, self.smoothMotionJobID == jobID,
                    case .media(var current) = self.project.item(id: itemID),
                    self.project.renderSettings.frameRate == frameRate,
                    current.canUseSmoothMotion, current.smoothMotionRecipe(frameRate: frameRate, mode: mode) == recipe,
                    self.project.mediaLibrary[current.mediaID]?.url == source
                else { return }
                let needsRefresh = current.usesSmoothMotion && current.smoothMotionMode == mode
                current.usesSmoothMotion = true
                current.smoothMotionMode = mode
                self.mutateProject { project in
                    project.replaceItem(id: itemID, with: .media(current))
                }
                if needsRefresh {
                    self.renderService.invalidatePreviewGraph()
                    self.schedulePreviewRebuild(seekTo: self.currentTime, delay: false,
                        invalidation: [.previewFrame, .compositionTopology])
                }
                self.showConfirmation("Smooth Motion ready")
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.smoothMotionJobID == jobID, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func disableSmoothMotion(for id: UUID) {
        guard !isPerformingLongTask, let location = project.itemLocation(id: id),
            !project.tracks[location.track].isLocked,
            case .media(var item) = project.tracks[location.track].items[location.item]
        else { return }
        item.usesSmoothMotion = false
        mutateProject { $0.replaceItem(id: id, with: .media(item)) }
    }

    private func updateSmoothMotionProgress(_ progress: Double, jobID: UUID) {
        guard smoothMotionJobID == jobID, let state = analysisState,
            state.kind == .smoothMotion, progress > state.progress else { return }
        analysisState?.progress = progress
    }
}
