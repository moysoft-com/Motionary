import AVFoundation
import Combine
import XCTest
import UIKit
import MediaToolbox
import Synchronization
@testable import Motionary

final class ProjectAudioPlaybackIntegrationTests: XCTestCase {
    @MainActor
    func testLivePlayerProcessesBothOpeningAudioLayers() async throws {
        let fixture = try fixtureURL()
        let id = UUID()
        let store = ProjectStore()
        let directory = store.projectFolderURL(for: id)
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = try ProjectArchive.extract(url: fixture, to: directory, projectID: id)
        let model = EditorViewModel(projectID: id, projectStore: store, initialContent: content)
        defer { model.suspendPreview() }
        let window = try mountPreview(model)
        defer { window.isHidden = true }
        let prepared = try await model.renderService.preparePreview(for: model.project, quality: .balanced,
            invalidation: [.compositionTopology, .previewFrame, .audioMix], renderSessionID: model.previewRenderSessionID)
        let preview = try XCTUnwrap(prepared)
        let composition = preview.composition
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = preview.videoComposition
        let mix = AVMutableAudioMix()
        var opening = [PlaybackAudioTap]()
        mix.inputParameters = try XCTUnwrap(preview.audioMix).inputParameters.map { original in
            let parameters = try XCTUnwrap(original.mutableCopy() as? AVMutableAudioMixInputParameters)
            if let track = composition.track(withTrackID: original.trackID),
                track.segments.contains(where: { !$0.isEmpty && $0.timeMapping.target.containsTime(.zero) }) {
                let tap = PlaybackAudioTap()
                parameters.audioTapProcessor = try tap.makeTap()
                opening.append(tap)
            }
            return parameters
        }
        XCTAssertEqual(opening.count, 2)
        item.audioMix = mix
        model.replacePreviewPlayer(with: item)
        model.installPreviewItemHealthObservers(for: item)
        model.installTimeObserver()
        model.togglePlayback()
        try await wait("Read the first second of live playback", model: model) {
            (model.player?.currentTime().seconds ?? 0) > 1
        }
        XCTAssertTrue(model.player?.currentItem === item)
        for tap in opening {
            print("Opening audio layer: \(tap.diagnostics)")
            XCTAssertLessThan(tap.firstSignal, 0.12, tap.diagnostics)
        }

    }

    @MainActor
    func testOpeningFrameAndSustainedScratchWithRemappedVideoAndEffects() async throws {
        let fixture = try fixtureURL()
        let projectID = UUID()
        let store = ProjectStore()
        let folder = store.projectFolderURL(for: projectID)
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = try ProjectArchive.extract(url: fixture, to: folder, projectID: projectID).editorProject
        let segmentDuration = project.duration
        for index in project.tracks.indices {
            let original = project.tracks[index].items
            project.tracks[index].items = try (0..<3).flatMap { repeatIndex in
                try original.map { item in
                    guard case .media(var clip) = item else { return item }
                    clip.id = UUID()
                    clip.timelineStart += Double(repeatIndex) * segmentDuration
                    if clip.mediaType == .video {
                        clip.visuals.effectStack.effects.append(
                            try XCTUnwrap(EffectRegistry.shared.makeEffect(moduleID: .lightSweep)))
                    }
                    return .media(clip)
                }
            }
        }
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppPreferences.djScratchingKey)
        defaults.set(true, forKey: AppPreferences.djScratchingKey)
        defer { defaults.set(previous, forKey: AppPreferences.djScratchingKey) }
        let model = EditorViewModel(projectID: projectID, projectStore: store,
                                    initialContent: ProjectContent(editorProject: project))
        defer { model.suspendPreview() }
        let window = try mountPreview(model)
        defer { window.isHidden = true }
        let recoveryGeneration = model.previewRecoveryGeneration
        model.start()
        try await wait("Display a frame while paused after opening", model: model) {
            model.hasRenderedInitialPreviewFrame && model.livePreviewPresentation.frame != nil
        }
        XCTAssertEqual(model.livePreviewPresentation.frameTime, 0)
        XCTAssertFalse(model.isPlaying)

        let frames = PlaybackVideoOutput()
        frames.attach(to: try XCTUnwrap(model.player?.currentItem))
        defer { frames.detach() }
        model.beginScrub()
        var displayedTimes = Set<Double>()
        for index in 0..<2_400 {
            let sweep = index / 100
            let progress = Double(index % 100) * 0.035
            let base = [0.2, 15.0, 31.0, 43.0][sweep % 4]
            model.updateScrub(to: min(project.duration - 0.1,
                base + (sweep.isMultiple(of: 2) ? progress : 3.5 - progress)))
            if let time = model.livePreviewPresentation.frameTime { displayedTimes.insert(time) }
            try await Task.sleep(for: .milliseconds(8))
        }
        print("Sustained scratch presented \(displayedTimes.count) distinct preview times.")
        XCTAssertGreaterThan(displayedTimes.count, 5)
        let target = segmentDuration + 2.3
        model.endScrub(at: target)
        try await wait("Finish the sustained scratch", model: model) { !model.isScrubbing }
        XCTAssertEqual(model.currentTime, target, accuracy: 1 / 60)
        XCTAssertEqual(try XCTUnwrap(model.player).currentTime().seconds, target, accuracy: 1 / 60)
        XCTAssertEqual(model.previewRecoveryGeneration, recoveryGeneration)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testArchivedProjectPlaysAndScrubsAcrossAudioEdits() async throws {
        let fixture = try fixtureURL()
        let defaults = UserDefaults.standard
        let previousScratchSetting = defaults.object(forKey: AppPreferences.djScratchingKey)
        defaults.set(true, forKey: AppPreferences.djScratchingKey)
        defer { defaults.set(previousScratchSetting, forKey: AppPreferences.djScratchingKey) }

        let store = ProjectStore()
        let projectID = UUID()
        let projectFolder = store.projectFolderURL(for: projectID)
        defer { try? FileManager.default.removeItem(at: projectFolder) }
        let content = try ProjectArchive.extract(
            url: fixture, to: projectFolder, projectID: projectID
        )
        let model = EditorViewModel(projectID: projectID, projectStore: store, initialContent: content)
        defer {
            model.suspendPreview()
            model.autosaveTask?.cancel()
            model.projectPosterTask?.cancel()
        }

        let audioTrackIndex = try XCTUnwrap(model.project.tracks.firstIndex { $0.kind == .audio })
        let music = try XCTUnwrap(model.project.tracks[audioTrackIndex].clips.first)
        let musicURL = try XCTUnwrap(model.project.mediaLibrary[music.mediaID]?.url)
        guard case .media(let video) = model.project.tracks.first(where: { $0.kind == .visual })?.items.first else {
            return XCTFail("The archive must start with a video clip")
        }
        let videoURL = try XCTUnwrap(model.project.mediaLibrary[video.mediaID]?.url)
        let videoRemap = try XCTUnwrap(video.speedMap.timeRemap)
        let firstKeyframe = try XCTUnwrap(videoRemap.keyframes.first)
        let probeTime = 0.32

        let clock = ContinuousClock()
        var results: [String] = []
        let window = try mountPreview(model)
        let frames = PlaybackVideoOutput()
        // Install the measuring output before AVPlayer prepares the new item.
        // Adding a second video consumer during playback can re-prime the decoder.
        let observation = model.$player.sink { player in
            if let item = player?.currentItem { frames.attach(to: item) }
        }
        defer {
            observation.cancel()
            frames.detach()
            window.isHidden = true
        }
        let initialRecoveryGeneration = model.previewRecoveryGeneration
        let scrubTargets = [14.6, 0.1, 6.2, 3.2, 11.5, 0.4, 9.9, 2.8, 14.6, 7.35]
        let originalIdentity: ObjectIdentifier
        do {
            let opening = clock.now
            model.start()
            model.togglePlayback()
            let original = try await observePlayback(of: model, near: 0, frames: frames, stage: "Open and immediately play")
            originalIdentity = ObjectIdentifier(original)
            results.append("Open and immediately play: \(opening.duration(to: clock.now))")
            model.togglePlayback()
            await model.previewPrerollTask?.value
            let pausedAt = model.currentTime
            let resume = clock.now
            model.togglePlayback()
            let resumed = try await observePlayback(of: model, near: pausedAt, frames: frames, stage: "Resume from rest")
            results.append("Resume from rest: \(resume.duration(to: clock.now))")
            XCTAssertTrue(resumed === original)
            model.togglePlayback()
            XCTAssertGreaterThan(try audioRMS(original, at: probeTime, source: musicURL), 0.01)
            XCTAssertGreaterThan(try audioRMS(original, at: probeTime, source: videoURL), 0.01)

            try await scrub(model, through: scrubTargets)
            let afterScrub = clock.now
            model.togglePlayback()
            let replayed = try await observePlayback(of: model, near: 7.35, frames: frames, stage: "Play at scrub destination")
            results.append("Play at scrub destination: \(afterScrub.duration(to: clock.now))")
            XCTAssertTrue(replayed === original)
            model.togglePlayback()
            for target in scrubTargets {
                XCTAssertGreaterThan(try audioRMS(original, at: target), 0.01, "PCM at \(target) s")
            }

            model.selectTimelineItem(music.id)
            model.setSelectedKeyframeValue(0, target: .volume)
            let volumeEdit = clock.now
            let volumeTarget = model.currentTime
            model.togglePlayback()
            let muted = try await observePlayback(of: model, near: volumeTarget, frames: frames, stage: "Play after volume edit")
            results.append("Play after volume edit: \(volumeEdit.duration(to: clock.now))")
            XCTAssertTrue(muted === original, "A volume-only edit can reuse the installed video composition")
            model.togglePlayback()
            XCTAssertLessThan(try audioRMS(muted, at: probeTime, source: musicURL), 0.0001)
            XCTAssertGreaterThan(try audioRMS(muted, at: probeTime, source: videoURL), 0.01)
        }

        model.placeTimelineItem(music.id, at: 0.8, proposedTrackIndex: audioTrackIndex)
        model.setSelectedKeyframeValue(music.volume.baseValue, target: .volume)
        model.selectTimelineItem(video.id)
        model.setSelectedTimeRemapInterpolation(.hold, startTime: firstKeyframe.time, interactive: false)
        let topologyEdit = clock.now
        let topologyTarget = model.currentTime
        model.togglePlayback()
        let edited = try await observePlayback(of: model, near: topologyTarget, frames: frames, stage: "Play after move and remap")
        results.append("Play after move and remap: \(topologyEdit.duration(to: clock.now))")
        XCTAssertNotEqual(ObjectIdentifier(edited), originalIdentity)
        model.togglePlayback()
        XCTAssertLessThan(try audioRMS(edited, at: probeTime, source: musicURL), 0.0001)
        XCTAssertLessThan(try audioRMS(edited, at: probeTime, source: videoURL), 0.0001)
        XCTAssertGreaterThan(try audioRMS(edited, at: 2.8, source: musicURL), 0.01)
        XCTAssertGreaterThan(try audioRMS(edited, at: 1.45, source: videoURL), 0.01)

        try await scrub(model, through: Array(scrubTargets.reversed()))
        XCTAssertEqual(model.previewRecoveryGeneration, initialRecoveryGeneration)
        XCTAssertNil(model.errorMessage)

        let report = results.joined(separator: "\n")
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "Archived project playback timings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testArchivedProjectSeeksAndPlaysAcrossTheFirstVideoCut() async throws {
        let fixture = try fixtureURL()
        let store = ProjectStore()
        let projectID = UUID()
        let projectFolder = store.projectFolderURL(for: projectID)
        defer { try? FileManager.default.removeItem(at: projectFolder) }
        let content = try ProjectArchive.extract(
            url: fixture, to: projectFolder, projectID: projectID
        )
        let model = EditorViewModel(projectID: projectID, projectStore: store, initialContent: content)
        defer { model.suspendPreview() }

        let music = try XCTUnwrap(model.project.tracks.first { $0.kind == .audio }?.clips.first)
        guard case .media(let video) = model.project.tracks.first(where: { $0.kind == .visual })?.items.first else {
            return XCTFail("The archive must start with a video clip")
        }
        let musicURL = try XCTUnwrap(model.project.mediaLibrary[music.mediaID]?.url)
        let videoURL = try XCTUnwrap(model.project.mediaLibrary[video.mediaID]?.url)
        let recoveryGeneration = model.previewRecoveryGeneration
        model.start()
        try await wait("Install preview before seeking", model: model) {
            model.player?.currentItem?.status == .readyToPlay && model.rebuildTask == nil
        }
        let item = try XCTUnwrap(model.player?.currentItem)
        let frames = PlaybackVideoOutput()
        frames.attach(to: item)
        defer { frames.detach() }
        let firstTarget = 0.32
        let afterCut = video.timelineEnd + 0.075
        for target in [firstTarget, afterCut] {
            model.seek(to: target)
            model.togglePlayback()
            let played = try await observePlayback(
                of: model, near: target, frames: frames, stage: "Play after seeking to \(target) s"
            )
            XCTAssertTrue(played === item)
            model.togglePlayback()
            XCTAssertGreaterThan(try audioRMS(played, at: target, source: musicURL), 0.01)
        }
        XCTAssertGreaterThan(try audioRMS(item, at: firstTarget, source: videoURL), 0.01)
        XCTAssertLessThan(try audioRMS(item, at: afterCut, source: videoURL), 0.0001)
        XCTAssertEqual(model.previewRecoveryGeneration, recoveryGeneration)
    }

    @MainActor
    func testArchivedPlaybackClearsPlayStateAtTheEndAndRestartsAtZero() async throws {
        let fixture = try fixtureURL()
        let projectID = UUID()
        let store = ProjectStore()
        let folder = store.projectFolderURL(for: projectID)
        defer { try? FileManager.default.removeItem(at: folder) }
        let content = try ProjectArchive.extract(url: fixture, to: folder, projectID: projectID)
        let model = EditorViewModel(projectID: projectID, projectStore: store, initialContent: content)
        defer { model.suspendPreview() }
        let frames = PlaybackVideoOutput()
        defer { frames.detach() }
        model.start()
        try await wait("Install preview", model: model) {
            guard let item = model.player?.currentItem else { return false }
            if frames.item !== item { frames.attach(to: item) }
            return model.rebuildTask == nil && item.status == .readyToPlay
        }
        model.seek(to: model.duration - 0.4)
        model.togglePlayback()
        let player = try XCTUnwrap(model.player)
        let item = try XCTUnwrap(player.currentItem)
        try await wait("Begin the final section", model: model) { player.timeControlStatus == .playing }
        try await wait("Stop at item end", model: model) { player.currentTime() >= item.duration }
        let end = ContinuousClock.now
        try await wait("Update the play button", model: model) {
            !model.isPlaying && !model.playbackState.isStartingPlayback
        }
        XCTAssertLessThan(end.duration(to: .now), .milliseconds(60))
        XCTAssertEqual(model.currentTime, model.duration)
        model.togglePlayback()
        _ = try await observePlayback(of: model, near: 0, frames: frames, stage: "Replay from end")
    }

    @MainActor
    func testScratchFollowsTheLatestPositionWhenOpeningAndAfterAnAudioEdit() async throws {
        let fixture = try fixtureURL()
        let projectID = UUID()
        let store = ProjectStore()
        let folder = store.projectFolderURL(for: projectID)
        defer { try? FileManager.default.removeItem(at: folder) }
        let content = try ProjectArchive.extract(url: fixture, to: folder, projectID: projectID)
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppPreferences.djScratchingKey)
        defaults.set(true, forKey: AppPreferences.djScratchingKey)
        defer { defaults.set(previous, forKey: AppPreferences.djScratchingKey) }
        let model = EditorViewModel(projectID: projectID, projectStore: store, initialContent: content)
        defer {
            model.suspendPreview()
            model.autosaveTask?.cancel()
        }
        let music = try XCTUnwrap(model.project.tracks.first { $0.kind == .audio }?.clips.first)
        model.start()
        model.beginScrub()
        let initialSweep = [0.3, 12.8, 3.2, 9.1, 6.4, 14.6, 7.35]
        for time in initialSweep {
            model.updateScrub(to: time)
            try await Task.sleep(for: .milliseconds(8))
        }
        try await wait("Prepare audio at the latest position while opening", model: model) {
            model.scratchAudio.hasPreparedAudio(at: model.currentTime)
        }
        XCTAssertTrue(model.isScrubbing)
        model.selectTimelineItem(music.id)
        model.setSelectedKeyframeValue(0.25, target: .volume)
        XCTAssertFalse(model.scratchAudio.hasPreparedAudio(at: model.currentTime))
        for time in initialSweep.reversed() {
            model.updateScrub(to: time)
            try await Task.sleep(for: .milliseconds(8))
        }
        try await wait("Prepare the edited mix during the same scrub", model: model) {
            model.scratchAudio.hasPreparedAudio(at: model.currentTime)
        }
        XCTAssertTrue(model.isScrubbing)
        XCTAssertEqual(model.currentTime, 0.3, accuracy: 0.001)
        model.endScrub(at: 0.3)
        try await wait("Finish scrubbing the edited mix", model: model) { !model.isScrubbing }
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testArchivedMusicScratchWindowsMatchTheSourceWaveform() async throws {
        let fixture = try fixtureURL()
        let projectID = UUID()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(projectID.uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try ProjectArchive.extract(url: fixture, to: folder, projectID: projectID).editorProject
        guard case .media(let music) = project.tracks.first(where: { $0.kind == .audio })?.items.first else {
            return XCTFail("The archive must include the music clip")
        }
        let url = try XCTUnwrap(project.mediaLibrary[music.mediaID]?.url)
        let reference = try await readSourceWaveform(url)
        let service = CompositionRenderService()
        let prepared = try await service.preparePreview(
            for: project, quality: .interactive, invalidation: [.previewFrame, .compositionTopology, .audioMix]
        )
        let preview = try XCTUnwrap(prepared)
        let tracks = audioTracks(in: preview.composition, from: url)
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first as? AVCompositionTrack)
        let segment = try XCTUnwrap(track.segments.first { !$0.isEmpty })
        let preparedFile = try AVAudioFile(forReading: XCTUnwrap(segment.sourceURL))
        XCTAssertEqual(preparedFile.fileFormat.channelCount, 2, "The archived soundtrack is stereo")
        let mapping = segment.timeMapping
        let native = try await service.makeComposition(for: project)
        let originalTrack = try XCTUnwrap(audioTracks(in: native.composition, from: url).first as? AVCompositionTrack)
        let original = try XCTUnwrap(originalTrack.segments.first { !$0.isEmpty }).timeMapping
        let speed = original.source.duration.seconds / original.target.duration.seconds
        XCTAssertEqual(speed, music.speedMap.constantSpeed, accuracy: 0.001)
        XCTAssertEqual(mapping.source.duration.seconds, mapping.target.duration.seconds, accuracy: 1.0 / 44_100)
        XCTAssertEqual(mapping.target.start.seconds, music.timelineStart, accuracy: 0.003)
        let cache = ScratchTimelineCache(asset: preview.composition, tracks: tracks, audioMix: preview.audioMix,
                                         duration: preview.duration)
        defer { cache.cancel() }
        let bank = ScratchSampleBank()
        let initialSlot = try XCTUnwrap(bank.beginWrite())
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(6)
        let farTarget = 13.3
        while !cache.fill(bank: bank, slot: initialSlot, around: farTarget, rate: 1) {
            guard clock.now < deadline else { return XCTFail("The fixture's music cache did not reach \(farTarget) s") }
            try await Task.sleep(for: .milliseconds(10))
        }

        for target in [farTarget, 0.1, 7.35, 3.2, 11.5, farTarget] {
            let sourceTime = original.source.start.seconds + (target - original.target.start.seconds) * speed
            let authoredTime = music.sourceRange.start + music.speedMap.sourceTime(
                at: target - music.timelineStart, sourceDuration: music.sourceRange.duration
            )
            XCTAssertEqual(sourceTime, authoredTime, accuracy: 0.003)
            let cachedSlot = try XCTUnwrap(bank.beginWrite())
            XCTAssertTrue(cache.fill(bank: bank, slot: cachedSlot, around: target))
            let cachedLag = try waveformLag(bank, at: target, matches: reference, at: sourceTime,
                                             speed: speed, path: "Warm cache")

            let demandSlot = try XCTUnwrap(bank.beginWrite())
            ScratchWindowDecoder.read(asset: preview.composition, tracks: tracks, audioMix: preview.audioMix,
                                      duration: preview.duration, around: target, bank: bank, slot: demandSlot,
                                      windowLength: 0.55, leading: 0.14, shouldContinue: { true })
            let demandLag = try waveformLag(bank, at: target, matches: reference, at: sourceTime,
                                             speed: speed, path: "Demand decode")
            XCTAssertLessThanOrEqual(abs(cachedLag - demandLag), 4, "Warm and demand offsets at \(target) s")
        }
    }

    private func readSourceWaveform(_ url: URL) async throws -> [Float] {
        let source = AVURLAsset(url: url)
        let rate = ScratchSampleBank.sampleRate
        let duration = try await source.load(.duration).seconds
        let tracks = try await source.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: source)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var waveform = [Float](repeating: 0, count: Int((duration * rate).rounded(.up)))
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isNumeric, let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let start = Int((pts.seconds * rate).rounded())
            let frames = CMSampleBufferGetNumSamples(sample)
            let first = max(0, -start)
            let end = min(frames, waveform.count - start)
            guard end > first else { continue }
            var stereo = [Float](repeating: 0, count: frames * 2)
            let result = stereo.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            XCTAssertEqual(result, kCMBlockBufferNoErr)
            for frame in first..<end {
                waveform[start + frame] = stereo[frame * 2]
            }
        }
        XCTAssertEqual(reader.status, .completed)
        return waveform
    }

    private func waveformLag(_ bank: ScratchSampleBank, at timelineTime: Double, matches reference: [Float],
                             at sourceTime: Double, speed: Double, path: String) throws -> Int {
        let window = try XCTUnwrap(bank.borrow())
        defer { bank.release() }
        let rate = ScratchSampleBank.sampleRate
        let timelineFrame = (timelineTime * rate).rounded()
        let sourceFrame = sourceTime * rate
        let searchRadius = 240
        guard reference.indices.contains(Int(sourceFrame) - searchRadius),
              reference.indices.contains(Int(sourceFrame + 4_800 * speed) + searchRadius + 1)
        else {
            XCTFail("Music fixture has no source samples at \(sourceTime) s")
            return 0
        }
        var best = -Double.infinity
        var bestLag = 0
        for lag in -searchRadius...searchRadius {
            var cross = 0.0
            var scratchEnergy = 0.0
            var sourceEnergy = 0.0
            for frame in stride(from: 0, to: 4_800, by: 4) {
                let scratch = Double(window.sample(at: timelineFrame + Double(frame), channel: 0))
                // Pitch follows speed, so each timeline sample advances
                // through the source at the clip's authored rate.
                let position = sourceFrame + Double(frame) * speed + Double(lag)
                let index = Int(position)
                let fraction = position - Double(index)
                let a = Double(reference[index])
                let original = a + (Double(reference[index + 1]) - a) * fraction
                cross += scratch * original
                scratchEnergy += scratch * scratch
                sourceEnergy += original * original
            }
            let similarity = cross / sqrt(scratchEnergy * sourceEnergy)
            if similarity > best {
                best = similarity
                bestLag = lag
            }
        }
        XCTAssertGreaterThan(best, 0.95, "\(path) at \(timelineTime) s")
        XCTAssertLessThanOrEqual(abs(bestLag), 144, "\(path) at \(timelineTime) s, sample lag \(bestLag)")
        return bestLag
    }

    @MainActor
    private func mountPreview(_ model: EditorViewModel) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        let host = PreviewRendererView.Host(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        host.playbackLayer = model.livePreviewPresentation.playerLayer
        window.rootViewController?.view.addSubview(host)
        window.isHidden = false
        return window
    }

    @MainActor
    private func observePlayback(
        of model: EditorViewModel, near target: Double, frames: PlaybackVideoOutput, stage: String
    ) async throws -> AVPlayerItem {
        var firstPlayingTime: Double?
        var displayedTime = CMTime.invalid
        var sampledClock = CMTime.invalid
        try await wait(stage, model: model) {
            guard let player = model.player, let item = player.currentItem else { return false }
            if frames.item !== item {
                frames.attach(to: item)
                firstPlayingTime = nil
            }
            let now = player.currentTime()
            guard model.isPlaying, player.timeControlStatus == .playing, now.isNumeric else {
                return false
            }
            let first = firstPlayingTime ?? now.seconds
            firstPlayingTime = first
            guard now.seconds >= first + 0.035 else { return false }
            sampledClock = now
            return frames.output?.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: &displayedTime) != nil
                && abs(displayedTime.seconds - now.seconds) < 0.10
        }
        let first = try XCTUnwrap(firstPlayingTime)
        XCTAssertEqual(first, target, accuracy: 0.25, stage)
        let frameDelay = sampledClock.seconds - first
        XCTAssertLessThan(frameDelay, 0.4, stage)
        print("\(stage). Target \(target) s, first playing clock \(first) s, frame \(displayedTime.seconds) s after \(frameDelay) s of clock progression.")
        XCTAssertNotNil(frames.item?.audioMix, stage)
        return try XCTUnwrap(frames.item)
    }

    @MainActor
    private func scrub(_ model: EditorViewModel, through times: [Double]) async throws {
        model.beginScrub()
        for time in times {
            model.updateScrub(to: time)
            try await Task.sleep(for: .milliseconds(16))
        }
        let destination = try XCTUnwrap(times.last)
        model.endScrub(at: destination)
        try await wait("Finish rapid scrub at \(destination)", model: model) { !model.isScrubbing }
        XCTAssertEqual(model.currentTime, destination, accuracy: 1.0 / 60)
        let player = try XCTUnwrap(model.player)
        XCTAssertEqual(player.currentTime().seconds, destination, accuracy: 1.0 / 60)
    }

    @MainActor
    private func wait(_ stage: String, model: EditorViewModel, until condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(6)
        while !condition() {
            guard clock.now < deadline else {
                let detail = "\(stage) timed out. Preview \(model.previewState.status), "
                    + "time \(model.currentTime), player \(String(describing: model.player?.currentTime().seconds)), "
                    + "status \(String(describing: model.player?.timeControlStatus)), "
                    + "error \(model.errorMessage ?? "none")"
                throw NSError(domain: "ProjectAudioPlaybackIntegrationTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: detail])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func audioTracks(in composition: AVComposition, from source: URL?) -> [AVAssetTrack] {
        composition.tracks(withMediaType: .audio).filter { track in
            guard let source else { return true }
            return track.segments.contains {
                guard !$0.isEmpty, let url = $0.sourceURL else { return false }
                return url.standardizedFileURL == source.standardizedFileURL
                    || url.deletingLastPathComponent().resolvingSymlinksInPath().path == PreviewRetimedAudio.directory(for: source).resolvingSymlinksInPath().path
            }
        }
    }

    private func audioRMS(_ item: AVPlayerItem, at time: Double, source: URL? = nil) throws -> Float {
        let composition = try XCTUnwrap(item.asset as? AVComposition)
        let audio = try XCTUnwrap(composition.mutableCopy() as? AVMutableComposition)
        audio.tracks(withMediaType: .video).forEach { audio.removeTrack($0) }
        let tracks = audioTracks(in: audio, from: source)
        XCTAssertFalse(tracks.isEmpty, "Expected original media on the shared playback timeline")
        let bank = ScratchSampleBank()
        let slot = try XCTUnwrap(bank.beginWrite())
        ScratchWindowDecoder.read(asset: audio, tracks: tracks, audioMix: item.audioMix,
                                  duration: composition.duration.seconds, around: time, bank: bank, slot: slot,
                                  windowLength: 0.2, leading: 0.02, shouldContinue: { true })
        let window = try XCTUnwrap(bank.borrow(), "Could not decode PCM at \(time) s")
        defer { bank.release() }
        let start = time * ScratchSampleBank.sampleRate
        return sqrt((0..<4_800).reduce(Float(0)) { energy, frame in
            let sample = window.sample(at: start + Double(frame), channel: 0)
            return energy + sample * sample
        } / 4_800)
    }

    private func fixtureURL() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["MOTIONARY_AUDIO_FIXTURE"] {
            return try XCTUnwrap(FileManager.default.isReadableFile(atPath: path) ? URL(fileURLWithPath: path) : nil,
                                 "The configured Motionary archive is unreadable")
        }
        // The archive can also be staged in the test bundle or app's Documents directory.
        if let fixture = Bundle(for: Self.self).url(forResource: "AudioPlaybackFixture", withExtension: "mpj") {
            return fixture
        }
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let fixture = documents.appendingPathComponent("AudioPlaybackFixture.mpj")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Set MOTIONARY_AUDIO_FIXTURE or stage AudioPlaybackFixture.mpj to run this test.")
        }
        return fixture
    }
}

@MainActor
private final class PlaybackVideoOutput {
    private(set) var output: AVPlayerItemVideoOutput?
    private(set) weak var item: AVPlayerItem?

    func attach(to item: AVPlayerItem) {
        detach()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        self.output = output
        self.item = item
        item.add(output)
    }

    func detach() {
        if let output { item?.remove(output) }
        output = nil
        item = nil
    }
}

private final class PlaybackAudioTap {
    private let signal = Atomic<Double>(.infinity)
    private let callbacks = Atomic<Int>(0)
    private let firstBufferTime = Atomic<Double>(.infinity)
    private var processingFormat = AudioStreamBasicDescription()

    var firstSignal: Double { signal.load(ordering: .relaxed) }
    var diagnostics: String {
        "\(firstSignal) s first signal, \(firstBufferTime.load(ordering: .relaxed)) s first buffer, "
            + "\(callbacks.load(ordering: .relaxed)) callbacks"
    }

    func makeTap() throws -> MTAudioProcessingTap {
        let owner = Unmanaged.passRetained(self)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: owner.toOpaque(),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in Unmanaged<PlaybackAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let probe = Unmanaged<PlaybackAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                probe.processingFormat = format.pointee
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                let probe = Unmanaged<PlaybackAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                _ = probe.callbacks.wrappingAdd(1, ordering: .relaxed)
                var range = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut)
                guard status == noErr, framesOut.pointee > 0, range.start.isNumeric else { return }
                _ = probe.firstBufferTime.compareExchange(expected: .infinity, desired: range.start.seconds,
                                                         ordering: .relaxed)
                probe.record(from: buffers, startingAt: range.start.seconds)
            }
        )
        var result: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                               kMTAudioProcessingTapCreationFlag_PostEffects, &result)
        guard status == noErr, let result else {
            owner.release()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return result
    }

    private func record(from buffers: UnsafeMutablePointer<AudioBufferList>, startingAt start: Double) {
        guard !firstSignal.isFinite, processingFormat.mFormatID == kAudioFormatLinearPCM,
              processingFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0, processingFormat.mBitsPerChannel == 32
        else { return }
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let samples = UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Float.self), count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            )
            if let index = samples.firstIndex(where: { abs($0) > 0.008 }) {
                let time = start + Double(index / Int(buffer.mNumberChannels)) / processingFormat.mSampleRate
                _ = signal.compareExchange(expected: .infinity, desired: time, ordering: .relaxed)
                return
            }
        }
    }
}
