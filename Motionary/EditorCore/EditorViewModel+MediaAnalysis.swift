// Blend-mode editing and shared on-device media-analysis workflows.

import Foundation

private struct BackgroundRemovalRequirement {
    let mediaID: MediaID
    let sourceURL: URL
    let clipName: String
    let sourceRange: TimeRangeValue
}

extension EditorViewModel {
    var selectedBlendMode: BlendMode? {
        selectedTimelineItem?.editableVisuals?.blendMode
    }

    var selectedBlendIntensity: Double? {
        selectedTimelineItem?.editableVisuals?.blendIntensity
    }

    var selectedBackgroundRemovalSettings: BackgroundRemovalSettings? {
        guard case .media(let item) = selectedTimelineItem,
            item.mediaType == .image || item.mediaType == .video
        else { return nil }
        return item.visuals.backgroundRemoval
    }

    var selectedBackgroundRemovalArtifactIsReady: Bool {
        guard case .media(let item) = selectedTimelineItem,
            let artifact = project.mediaLibrary[item.mediaID]?.backgroundRemovalArtifact
        else { return false }
        return !invalidBackgroundRemovalMediaIDs.contains(item.mediaID)
            && artifact.algorithmVersion == BackgroundRemovalArtifact.currentAlgorithmVersion
            && artifact.covers(item.sourceRange)
            && FileManager.default.fileExists(atPath: artifact.url.path)
    }

    var selectedAudioBeatAnalysis: AudioBeatAnalysis? {
        guard case .media(let item) = selectedTimelineItem,
            item.mediaType == .audio
        else { return nil }
        return item.beatAnalysis
    }

    func setSelectedBlendMode(_ blendMode: BlendMode) {
        guard let itemID = selectedTimelineItemID else { return }
        mutateProject { project in
            guard var item = project.item(id: itemID), var visuals = item.editableVisuals else { return }
            visuals.blendMode = blendMode
            item.editableVisuals = visuals
            project.replaceItem(id: itemID, with: item)
        }
    }

    func setSelectedBlendIntensity(_ intensity: Double, interactive: Bool = false) {
        guard let itemID = selectedTimelineItemID else { return }
        if interactive { beginInteractiveEdit() }
        mutateProject(
            rebuild: !interactive,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive,
            refreshTimeline: false
        ) { project in
            guard var item = project.item(id: itemID), var visuals = item.editableVisuals else { return }
            visuals.blendIntensity = min(max(intensity.isFinite ? intensity : 1, 0), 1)
            item.editableVisuals = visuals
            project.replaceItem(id: itemID, with: item)
        }
        if interactive {
            scheduleInteractivePreviewRebuild(invalidation: [.previewFrame])
        }
    }

    func enableSelectedBackgroundRemoval() {
        guard case .media(let item) = selectedTimelineItem,
            item.mediaType == .image || item.mediaType == .video
        else { return }
        startBackgroundRemovalPreparation(for: item.id, force: false, enableAfterPreparation: true)
    }

    func regenerateSelectedBackgroundRemoval() {
        guard case .media(let item) = selectedTimelineItem,
            item.mediaType == .image || item.mediaType == .video
        else { return }
        startBackgroundRemovalPreparation(
            for: item.id,
            force: true,
            enableAfterPreparation: item.visuals.backgroundRemoval == nil
        )
    }

    func disableSelectedBackgroundRemoval() {
        guard let itemID = selectedTimelineItemID else { return }
        mutateProject { project in
            guard var item = project.item(id: itemID), var visuals = item.editableVisuals else { return }
            visuals.backgroundRemoval = nil
            item.editableVisuals = visuals
            project.replaceItem(id: itemID, with: item)
        }
    }

    func setSelectedBackgroundRemovalSettings(
        edgeRefinement: Double? = nil,
        feather: Double? = nil,
        interactive: Bool = false
    ) {
        guard let itemID = selectedTimelineItemID else { return }
        if interactive { beginInteractiveEdit() }
        mutateProject(
            rebuild: !interactive,
            recordHistory: !interactive,
            persistChanges: !interactive,
            touchUpdatedAt: !interactive,
            refreshTimeline: false
        ) { project in
            guard var item = project.item(id: itemID), var visuals = item.editableVisuals,
                var settings = visuals.backgroundRemoval
            else { return }
            settings = BackgroundRemovalSettings(
                edgeRefinement: edgeRefinement ?? settings.edgeRefinement,
                feather: feather ?? settings.feather
            )
            visuals.backgroundRemoval = settings
            item.editableVisuals = visuals
            project.replaceItem(id: itemID, with: item)
        }
        if interactive {
            scheduleInteractivePreviewRebuild(invalidation: [.previewFrame])
        }
    }

    func analyzeSelectedAudioBeats() {
        guard case .media(let item) = selectedTimelineItem,
            item.mediaType == .audio,
            !isPerformingLongTask
        else { return }
        let itemID = item.id
        let mediaID = item.mediaID
        guard let asset = project.mediaLibrary[mediaID] else { return }
        let sourceURL = projectStore.resolvedMediaURL(asset.url, projectID: projectID)

        beginMediaAnalysis(.audioBeats)
        analysisTask = Task { [weak self] in
            guard let self else { return }
            defer {
                analysisState = nil
                analysisTask = nil
            }
            do {
                let analysis = try await AudioBeatAnalysisService().analyze(
                    url: sourceURL
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.updateAnalysisProgress(progress, kind: .audioBeats)
                    }
                }
                try Task.checkCancellation()
                mutateProject(rebuild: false) { project in
                    guard let location = project.itemLocation(id: itemID),
                        case .media(var current) = project.tracks[location.track].items[location.item],
                        current.mediaID == mediaID
                    else { return }
                    current.beatAnalysis = analysis
                    project.tracks[location.track].items[location.item] = .media(current)
                }
                showConfirmation("Beat markers added")
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteSelectedBeatMarkers() {
        guard let itemID = selectedTimelineItemID else { return }
        mutateProject(rebuild: false) { project in
            guard let location = project.itemLocation(id: itemID),
                case .media(var item) = project.tracks[location.track].items[location.item],
                item.mediaType == .audio
            else { return }
            item.beatAnalysis = nil
            project.tracks[location.track].items[location.item] = .media(item)
        }
    }

    @discardableResult
    func prepareEnabledBackgroundRemovalArtifactsOnOpen() -> Bool {
        let requirements = backgroundRemovalRequirements()
        guard !requirements.isEmpty, analysisTask == nil else { return false }
        beginMediaAnalysis(
            .backgroundRemoval,
            blocksEditor: false,
            pausesPlayback: false
        )
        analysisTask = Task { [weak self] in
            guard let self else { return }
            defer {
                analysisState = nil
                analysisTask = nil
            }
            do {
                _ = try await prepareBackgroundRemovalArtifacts(
                    requirements,
                    forceMediaIDs: []
                )
                try Task.checkCancellation()
                schedulePreviewRebuild(
                    seekTo: currentTime,
                    delay: false,
                    invalidation: [.previewFrame, .compositionTopology]
                )
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        return true
    }

    func prepareBackgroundRemovalArtifactsForExport() async throws {
        let requirements = backgroundRemovalRequirements()
        guard !requirements.isEmpty else { return }
        beginMediaAnalysis(.backgroundRemoval)
        defer { analysisState = nil }
        _ = try await prepareBackgroundRemovalArtifacts(requirements, forceMediaIDs: [])
    }

    @discardableResult
    func prepareSelectedBackgroundRemovalExtensionIfNeeded() -> Bool {
        guard case .media(let item) = selectedTimelineItem,
            item.visuals.backgroundRemoval != nil,
            !selectedBackgroundRemovalArtifactIsReady,
            !isPerformingLongTask
        else { return false }
        startBackgroundRemovalPreparation(
            for: item.id,
            force: false,
            enableAfterPreparation: false
        )
        return true
    }

    private func startBackgroundRemovalPreparation(
        for itemID: UUID,
        force: Bool,
        enableAfterPreparation: Bool
    ) {
        guard !isPerformingLongTask,
            let requirements = backgroundRemovalRequirements(including: itemID),
            let targetItem = project.item(id: itemID),
            case .media = targetItem
        else { return }

        beginMediaAnalysis(.backgroundRemoval)
        analysisTask = Task { [weak self] in
            guard let self else { return }
            defer {
                analysisState = nil
                analysisTask = nil
            }
            do {
                _ = try await prepareBackgroundRemovalArtifacts(
                    [requirements],
                    forceMediaIDs: force ? [requirements.mediaID] : []
                )
                try Task.checkCancellation()
                if enableAfterPreparation {
                    mutateProject { project in
                        guard var item = project.item(id: itemID), var visuals = item.editableVisuals else { return }
                        visuals.backgroundRemoval = visuals.backgroundRemoval ?? BackgroundRemovalSettings()
                        item.editableVisuals = visuals
                        project.replaceItem(id: itemID, with: item)
                    }
                } else {
                    schedulePreviewRebuild(
                        seekTo: currentTime,
                        delay: false,
                        invalidation: [.previewFrame, .compositionTopology]
                    )
                }
                showConfirmation("Background matte ready")
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func backgroundRemovalRequirements(
        including itemID: UUID? = nil
    ) -> BackgroundRemovalRequirement? {
        guard let itemID,
            case .media(let includedItem) = project.item(id: itemID),
            includedItem.mediaType == .image || includedItem.mediaType == .video,
            let asset = project.mediaLibrary[includedItem.mediaID]
        else { return nil }

        let matchingItems = project.tracks.flatMap(\.items).compactMap { item -> MediaTimelineItem? in
            guard case .media(let media) = item,
                media.mediaID == includedItem.mediaID,
                media.id == itemID || media.visuals.backgroundRemoval != nil
            else { return nil }
            return media
        }
        let range = Self.coveringRange(matchingItems.map(\.sourceRange)) ?? includedItem.sourceRange
        return BackgroundRemovalRequirement(
            mediaID: includedItem.mediaID,
            sourceURL: projectStore.resolvedMediaURL(asset.url, projectID: projectID),
            clipName: includedItem.name,
            sourceRange: range
        )
    }

    private func backgroundRemovalRequirements() -> [BackgroundRemovalRequirement] {
        let enabledItems = project.tracks.flatMap(\.items).compactMap { item -> MediaTimelineItem? in
            guard case .media(let media) = item,
                media.visuals.backgroundRemoval != nil,
                media.mediaType == .image || media.mediaType == .video
            else { return nil }
            return media
        }
        return Dictionary(grouping: enabledItems, by: \.mediaID).compactMap { mediaID, items in
            guard let asset = project.mediaLibrary[mediaID],
                let range = Self.coveringRange(items.map(\.sourceRange)),
                let first = items.first
            else { return nil }
            return BackgroundRemovalRequirement(
                mediaID: mediaID,
                sourceURL: projectStore.resolvedMediaURL(asset.url, projectID: projectID),
                clipName: first.name,
                sourceRange: range
            )
        }
    }

    private func prepareBackgroundRemovalArtifacts(
        _ requirements: [BackgroundRemovalRequirement],
        forceMediaIDs: Set<MediaID>
    ) async throws -> Bool {
        var changed = false
        let count = max(requirements.count, 1)
        for (index, requirement) in requirements.enumerated() {
            try Task.checkCancellation()
            updateAnalysisProgress(Double(index) / Double(count), kind: .backgroundRemoval)
            let fingerprint: String
            do {
                fingerprint = try await MediaFingerprint.sha256(for: requirement.sourceURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                invalidBackgroundRemovalMediaIDs.insert(requirement.mediaID)
                throw error
            }
            try Task.checkCancellation()

            let storedArtifact = project.mediaLibrary[requirement.mediaID]?.backgroundRemovalArtifact
            var artifact = storedArtifact
            if var resolvedArtifact = artifact {
                resolvedArtifact.url = projectStore.resolvedMediaURL(
                    resolvedArtifact.url,
                    projectID: projectID
                )
                artifact = resolvedArtifact
            }
            let artifactIsReusable = artifact.map {
                $0.algorithmVersion == BackgroundRemovalArtifact.currentAlgorithmVersion
                    && $0.sourceFingerprint == fingerprint
                    && FileManager.default.fileExists(atPath: $0.url.path)
            } ?? false
            let requiredRange: TimeRangeValue
            if artifactIsReusable, let artifact {
                requiredRange = Self.coveringRange([artifact.sourceRange, requirement.sourceRange])
                    ?? requirement.sourceRange
            } else {
                requiredRange = requirement.sourceRange
            }

            let mustGenerate = forceMediaIDs.contains(requirement.mediaID)
                || !artifactIsReusable
                || !(artifact?.covers(requirement.sourceRange) ?? false)
            let artifactSatisfiesRequirement = artifactIsReusable
                && (artifact?.covers(requirement.sourceRange) ?? false)
            if !artifactSatisfiesRequirement {
                invalidBackgroundRemovalMediaIDs.insert(requirement.mediaID)
            }
            if mustGenerate {
                let destinationURL = artifact?.url
                    ?? projectStore.derivedMediaURL(
                        fileName: "remove-bg-\(requirement.mediaID.rawValue.uuidString).mov",
                        projectID: projectID
                    )
                let baseProgress = Double(index) / Double(count)
                let generated = try await BackgroundRemovalService().generateMatte(
                    sourceURL: requirement.sourceURL,
                    sourceRange: requiredRange,
                    destinationURL: destinationURL,
                    fingerprint: fingerprint
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.updateAnalysisProgress(
                            baseProgress + progress / Double(count),
                            kind: .backgroundRemoval
                        )
                    }
                }
                artifact = generated
                invalidBackgroundRemovalMediaIDs.remove(requirement.mediaID)
                changed = true
            } else {
                invalidBackgroundRemovalMediaIDs.remove(requirement.mediaID)
            }

            if let artifact, artifact != storedArtifact {
                mutateProject(
                    rebuild: false,
                    recordHistory: false,
                    persistChanges: true,
                    touchUpdatedAt: false,
                    refreshTimeline: false
                ) { project in
                    project.mediaLibrary[requirement.mediaID]?.backgroundRemovalArtifact = artifact
                }
            }
            updateAnalysisProgress(Double(index + 1) / Double(count), kind: .backgroundRemoval)
        }
        return changed
    }

    private func updateAnalysisProgress(_ progress: Double, kind: EditorAnalysisKind) {
        guard let currentState = analysisState, currentState.kind == kind else { return }
        analysisState = EditorAnalysisState(
            kind: kind,
            progress: min(max(progress, 0), 1),
            blocksEditor: currentState.blocksEditor
        )
    }

    private func beginMediaAnalysis(
        _ kind: EditorAnalysisKind,
        blocksEditor: Bool = true,
        pausesPlayback: Bool = true
    ) {
        if pausesPlayback {
            player?.pause()
            isPlaying = false
        }
        analysisState = EditorAnalysisState(
            kind: kind,
            progress: 0,
            blocksEditor: blocksEditor
        )
    }

    private static func coveringRange(_ ranges: [TimeRangeValue]) -> TimeRangeValue? {
        guard let first = ranges.first else { return nil }
        let start = ranges.dropFirst().reduce(first.start) { min($0, $1.start) }
        let end = ranges.dropFirst().reduce(first.end) { max($0, $1.end) }
        return TimeRangeValue(start: start, duration: end - start)
    }
}
