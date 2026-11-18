@preconcurrency import AVFoundation
import Foundation
import QuartzCore
import Testing
@testable import Motionary

@Suite(.serialized)
struct TimelineScratchAudioTests {
    @Test func mutedAudioLayerIsExcludedFromTheComposition() async throws {
        let url = try makeConstantAudio(value: 0.25)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = ClipSource(url: url, mediaType: .audio, originalDuration: 1)
        let clip = TimelineClip(
            name: "Test audio", source: source, timelineStart: 0,
            sourceRange: TimeRangeValue(start: 0, duration: 1)
        )
        var project = EditorProject(
            title: "Audio mute", renderSettings: RenderSettings(width: 160, height: 96),
            tracks: [TimelineTrack(name: "Audio", kind: .audio, clips: [clip])]
        )
        let service = CompositionRenderService()
        let audible = try await service.makeComposition(for: project)
        #expect(audible.audioTrackIDs[clip.id] != nil)

        project.tracks[0].isMuted = true
        let muted = try await service.makeComposition(for: project)
        #expect(muted.audioTrackIDs.isEmpty)
        #expect(muted.duration == audible.duration)
    }

    @Test func preferenceDefaultsOffPersistsAndResets() {
        let suite = "scratch-preferences-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!AppPreferences.djScratchingValue(in: defaults))
        defaults.set(true, forKey: AppPreferences.djScratchingKey)
        #expect(AppPreferences.djScratchingValue(in: defaults))
        AppPreferences.reset(defaults: defaults)
        #expect(!AppPreferences.djScratchingValue(in: defaults))
    }

    @Test func velocityFollowsDirectionSpeedAndStopsAfterIdle() {
        var velocity = ScratchVelocity()
        velocity.reset(time: 1, hostTime: 10)
        #expect(velocity.update(time: 1.02, hostTime: 10.02) > 0)
        #expect(velocity.update(time: 0.98, hostTime: 10.04) < 0)
        #expect(abs(velocity.update(time: 9, hostTime: 10.06)) <= 8)
        #expect(velocity.update(time: 9, hostTime: 11) == 0)
    }

    @Test func batchedScrollSamplesPreserveDirectionAndDisplacement() {
        var velocity = ScratchVelocity()
        velocity.reset(time: 0, hostTime: 10)
        #expect(velocity.update(time: 0.05, hostTime: 10.0005) == 0)
        let forward = velocity.update(time: 0.06, hostTime: 10.01)
        #expect(forward > 1)
        #expect(velocity.update(time: 0.065, hostTime: 10.0105) == forward)
        #expect(velocity.update(time: 0.02, hostTime: 10.02) < 0)
    }

    @Test func samplesRunBothWaysAndFadeToSilenceOnReleaseAndIdle() throws {
        let bank = ScratchSampleBank()
        let slot = try #require(bank.beginWrite())
        for frame in 0..<ScratchSampleBank.capacity {
            let value = Float(frame) / Float(ScratchSampleBank.capacity) - 0.5
            bank.slots[slot].samples[frame * 2] = value
            bank.slots[slot].samples[frame * 2 + 1] = -value
        }
        bank.publish(slot: slot, start: 0, count: ScratchSampleBank.capacity)
        let control = ScratchAudioControl()
        let renderer = ScratchAudioRenderer(control: control, bank: bank)
        control.active.store(true, ordering: .releasing)
        control.update(time: 2, rate: 1, hostTime: 10)
        let forward = render(renderer, count: 4096, hostTime: 10)
        #expect(forward.left[4000] > forward.left[3200])
        #expect(zip(forward.left, forward.right).allSatisfy { abs($0 + $1) < 0.000_01 })
        control.update(time: 2.04, rate: -1, hostTime: 10.09)
        let reverse = render(renderer, count: 2048, hostTime: 10.09)
        #expect(reverse.left[1800] < reverse.left[1000])
        let idle = render(renderer, count: 1024, hostTime: 10.3)
        #expect(idle.left.suffix(500).allSatisfy { $0 == 0 })
        control.active.store(false, ordering: .releasing)
        let stopped = render(renderer, count: 1024, hostTime: 10.31)
        #expect(stopped.left.allSatisfy { $0 == 0 })
        #expect((forward.left + reverse.left).allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    @Test func fasterMovementRaisesPitchInsteadOfTimeStretching() throws {
        let bank = ScratchSampleBank()
        let slot = try #require(bank.beginWrite())
        for frame in 0..<ScratchSampleBank.capacity {
            let value = Float(sin(Double(frame) * 440 * 2 * .pi / ScratchSampleBank.sampleRate)) * 0.5
            bank.slots[slot].samples[frame * 2] = value
            bank.slots[slot].samples[frame * 2 + 1] = value
        }
        bank.publish(slot: slot, start: 0, count: ScratchSampleBank.capacity)
        func crossings(rate: Double) -> Int {
            let control = ScratchAudioControl()
            control.active.store(true, ordering: .releasing)
            control.update(time: 2, rate: rate, hostTime: 10)
            let renderer = ScratchAudioRenderer(control: control, bank: bank)
            let wave = Array(render(renderer, count: 8192, hostTime: 10).left.suffix(4096))
            return zip(wave, wave.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        }
        let normal = crossings(rate: 1)
        let fast = crossings(rate: 2)
        #expect(normal > 20)
        #expect(abs(fast - normal * 2) <= 2)
    }

    @Test func decoderCannotOverwriteTheWindowBorrowedByAudio() throws {
        let bank = ScratchSampleBank()
        let first = try #require(bank.beginWrite())
        bank.publish(slot: first, start: 0, count: 1000)
        _ = try #require(bank.borrow())
        let second = try #require(bank.beginWrite())
        bank.publish(slot: second, start: 1000, count: 1000)
        #expect(bank.beginWrite() == nil)
        bank.release()
        #expect(bank.beginWrite() == first)
    }

    @Test func inFlightRefillFromPreviousAudioRevisionCannotPlayAfterEdit() throws {
        let bank = ScratchSampleBank()
        let first = try #require(bank.beginWrite())
        bank.slots[first].samples.update(repeating: 0.4, count: ScratchSampleBank.capacity * 2)
        bank.publish(slot: first, start: 0, count: ScratchSampleBank.capacity)
        let control = ScratchAudioControl()
        let renderer = ScratchAudioRenderer(control: control, bank: bank)
        control.active.store(true, ordering: .releasing)
        control.update(time: 2, rate: 1, hostTime: 10)
        #expect(render(renderer, count: 2048, hostTime: 10).left.last! > 0.3)

        let late = try #require(bank.beginWrite())
        bank.generation.store(1, ordering: .releasing)
        bank.slots[late].samples.update(repeating: 0.6, count: ScratchSampleBank.capacity * 2)
        bank.publish(slot: late, start: 0, count: ScratchSampleBank.capacity)
        #expect(!bank.covers(time: 2, rate: 1, duration: 8))
        #expect(render(renderer, count: 1024, hostTime: 10.01).left.allSatisfy { $0 == 0 })

        let replacement = try #require(bank.beginWrite())
        bank.slots[replacement].samples.update(repeating: -0.4, count: ScratchSampleBank.capacity * 2)
        bank.publish(slot: replacement, start: 0, count: ScratchSampleBank.capacity, generation: 1)
        control.update(time: 2.02, rate: 1, hostTime: 10.02)
        let afterEdit = render(renderer, count: 2048, hostTime: 10.02).left
        #expect(afterEdit.allSatisfy { $0 <= 0 })
        #expect(afterEdit.last! < -0.3)
    }

    @Test func obsoleteDemandReadCannotEvictTheAudibleWindow() async throws {
        let url = try makeConstantAudio(value: 0.2)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let bank = ScratchSampleBank()
        let playing = try #require(bank.beginWrite())
        bank.slots[playing].samples.update(repeating: 0.6, count: ScratchSampleBank.capacity * 2)
        bank.publish(slot: playing, start: 10 * 48_000, count: 48_000)
        let pending = try #require(bank.beginWrite())
        var consideredForPublication = false
        ScratchWindowDecoder.read(asset: asset, tracks: tracks, audioMix: nil, duration: 1,
            around: 0.5, bank: bank, slot: pending,
            shouldPublish: { _, _ in
                consideredForPublication = true
                return false
            }, shouldContinue: { true })

        #expect(consideredForPublication)
        let window = try #require(bank.borrow())
        defer { bank.release() }
        #expect(window.start == 10 * 48_000)
        #expect(window.sample(at: 10.5 * 48_000, channel: 0) == 0.6)
    }

    @Test func decodedTimelineMixHonorsVolumeOverlapAndSilence() async throws {
        let firstURL = try makeConstantAudio(value: 0.8)
        let secondURL = try makeConstantAudio(value: 0.4)
        defer { try? FileManager.default.removeItem(at: firstURL); try? FileManager.default.removeItem(at: secondURL) }
        let firstAsset = AVURLAsset(url: firstURL)
        let secondAsset = AVURLAsset(url: secondURL)
        let firstSource = try #require(try await firstAsset.loadTracks(withMediaType: .audio).first)
        let secondSource = try #require(try await secondAsset.loadTracks(withMediaType: .audio).first)
        let composition = AVMutableComposition()
        let first = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let second = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 48_000))
        try first.insertTimeRange(range, of: firstSource, at: .zero)
        try second.insertTimeRange(range, of: secondSource, at: CMTime(seconds: 0.5, preferredTimescale: 48_000))
        let firstMix = AVMutableAudioMixInputParameters(track: first)
        firstMix.setVolume(0.25, at: .zero)
        let secondMix = AVMutableAudioMixInputParameters(track: second)
        secondMix.setVolume(0.5, at: .zero)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [firstMix, secondMix]
        let bank = ScratchSampleBank()
        let slot = try #require(bank.beginWrite())
        ScratchWindowDecoder.read(asset: composition, tracks: [first, second], audioMix: mix,
                                  duration: 2, around: 0, bank: bank, slot: slot, shouldContinue: { true })
        let window = try #require(bank.borrow())
        defer { bank.release() }
        #expect(abs(window.sample(at: 0.25 * 48_000, channel: 0) - 0.2) < 0.01)
        #expect(abs(window.sample(at: 0.75 * 48_000, channel: 0) - 0.4) < 0.01)
        #expect(abs(window.sample(at: 1.25 * 48_000, channel: 0) - 0.2) < 0.01)
        #expect(window.sample(at: 1.75 * 48_000, channel: 0) == 0)
    }

    @Test func waveformZoomReusesDecodedAudioAtDifferentResolutions() async throws {
        let url = try makeConstantAudio(value: 0.4)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = ClipSource(url: url, mediaType: .audio, originalDuration: 1)
        let clip = TimelineClip(name: "Waveform", source: source, timelineStart: 0,
                                sourceRange: TimeRangeValue(start: 0, duration: 1))
        let media = ClipMediaDescriptor(asset: MediaAsset(id: clip.mediaID, source: source))
        let cache = TimelineAudioWaveformCache()

        let zoomedOut = await cache.samples(for: clip, media: media, speedMap: .constant, targetCount: 96)
        try #require(zoomedOut.count == 96)
        #expect(zoomedOut[zoomedOut.count / 2] > 0.5)

        // A different drawing resolution must use the same source envelope.
        try FileManager.default.removeItem(at: url)
        let zoomedIn = await cache.samples(for: clip, media: media, speedMap: .constant, targetCount: 512)
        try #require(zoomedIn.count == 512)
        #expect(zoomedIn[zoomedIn.count / 2] > 0.5)
    }

    @Test func audioEngineSourceActuallyProducesStereoAudioAndStops() throws {
        let bank = ScratchSampleBank()
        let slot = try #require(bank.beginWrite())
        for frame in 0..<ScratchSampleBank.capacity {
            let value = Float(sin(Double(frame) * 330 * 2 * .pi / 48_000)) * 0.4
            bank.slots[slot].samples[frame * 2] = value
            bank.slots[slot].samples[frame * 2 + 1] = -value
        }
        bank.publish(slot: slot, start: 0, count: ScratchSampleBank.capacity)
        let control = ScratchAudioControl()
        let renderer = ScratchAudioRenderer(control: control, bank: bank)
        let engine = AVAudioEngine()
        let node = renderer.makeSourceNode()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        try engine.start()
        defer { engine.stop() }
        let output = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1024))
        control.active.store(true, ordering: .releasing)
        control.update(time: 2, rate: -1, hostTime: CACurrentMediaTime())
        #expect(try engine.renderOffline(1024, to: output) == .success)
        let left = UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
        #expect(left.contains { abs($0) > 0.1 })
        control.active.store(false, ordering: .releasing)
        #expect(try engine.renderOffline(1024, to: output) == .success)
        let stopped = UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
        #expect(stopped.suffix(500).allSatisfy { abs($0) < 0.000_01 })
    }

    @Test func preparedPCMCacheServesDistantJumpsAndKeepsRealSilentGaps() async throws {
        let url = try makeConstantAudio(value: 0.8)
        let distantURL = try makeConstantAudio(value: 0.4)
        defer { try? FileManager.default.removeItem(at: url) }
        defer { try? FileManager.default.removeItem(at: distantURL) }
        let asset = AVURLAsset(url: url)
        let distantAsset = AVURLAsset(url: distantURL)
        let source = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let distantSource = try #require(try await distantAsset.loadTracks(withMediaType: .audio).first)
        let composition = AVMutableComposition()
        let track = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 48_000))
        try track.insertTimeRange(range, of: source, at: .zero)
        let distantStart = CMTime(seconds: 40, preferredTimescale: 48_000)
        try track.insertTimeRange(range, of: distantSource, at: distantStart)
        track.scaleTimeRange(
            CMTimeRange(start: distantStart, duration: range.duration),
            toDuration: CMTime(seconds: 0.5, preferredTimescale: 48_000)
        )
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(0.25, at: .zero)
        parameters.audioTimePitchAlgorithm = .varispeed
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        let warmingQueue = DispatchQueue(label: "scratch-test-warming")
        let cache = ScratchTimelineCache(asset: composition, tracks: [track], audioMix: mix, duration: 41,
                                         queue: warmingQueue)
        defer { cache.cancel() }
        // Let warming finish without asking for any particular position. The
        // first lookup, including a distant retimed clip, should be a hit.
        await withCheckedContinuation { continuation in
            warmingQueue.async { continuation.resume() }
        }
        let bank = ScratchSampleBank()
        let slot = try #require(bank.beginWrite())
        try #require(cache.fill(bank: bank, slot: slot, around: 40.25))
        let distant = try #require(bank.borrow())
        #expect(abs(distant.sample(at: 40.25 * 48_000, channel: 0) - 0.1) < 0.01)
        #expect(distant.sample(at: 40.75 * 48_000, channel: 0) == 0)
        bank.release()
        let next = try #require(bank.beginWrite())
        try #require(cache.fill(bank: bank, slot: next, around: 20))
        let gap = try #require(bank.borrow())
        #expect(gap.start <= 20 * 48_000)
        #expect(gap.sample(at: 20 * 48_000, channel: 0) == 0)
        bank.release()
        let near = try #require(bank.beginWrite())
        try #require(cache.fill(bank: bank, slot: near, around: 0.5))
        let beginning = try #require(bank.borrow())
        #expect(abs(beginning.sample(at: 0.5 * 48_000, channel: 0) - 0.2) < 0.01)
        bank.release()
        var timings: [Double] = []
        for time in [0.5, 20.0, 40.25, 0.5, 40.25, 20.0] {
            let index = try #require(bank.beginWrite())
            let start = ProcessInfo.processInfo.systemUptime
            #expect(cache.fill(bank: bank, slot: index, around: time))
            timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        Attachment.record("PCM window refill across 40-second jumps, ms: \(timings)", named: "scratch-refill-latency.txt")
        cache.cancel()
        #expect(!cache.fill(bank: bank, slot: slot, around: 0.5))

        let coldSlot = try #require(bank.beginWrite())
        ScratchWindowDecoder.read(asset: composition, tracks: [track], audioMix: mix, duration: 41, around: 40.25,
                                  bank: bank, slot: coldSlot, windowLength: 0.55, leading: 0.12) { true }
        let cold = try #require(bank.borrow())
        #expect(abs(cold.sample(at: 40.25 * 48_000, channel: 0) - 0.1) < 0.01)
        #expect(cold.sample(at: 40.6 * 48_000, channel: 0) == 0)
        bank.release()
    }

    @Test func shortRefillKeepsContinuityThenFadesRatherThanHardMuting() throws {
        let bank = ScratchSampleBank()
        let slot = try #require(bank.beginWrite())
        bank.slots[slot].samples.update(repeating: 0.4, count: ScratchSampleBank.capacity * 2)
        bank.publish(slot: slot, start: 0, count: ScratchSampleBank.capacity)
        let control = ScratchAudioControl()
        let renderer = ScratchAudioRenderer(control: control, bank: bank)
        control.active.store(true, ordering: .releasing)
        control.update(time: 2, rate: 1, hostTime: 10)
        _ = render(renderer, count: 1024, hostTime: 10)
        control.update(time: 20, rate: 1, hostTime: 10.02)
        let bridge = render(renderer, count: 256, hostTime: 10.02)
        #expect(bridge.left.allSatisfy { $0 > 0.1 })
        let faded = render(renderer, count: 1024, hostTime: 10.06)
        #expect(faded.left.suffix(500).allSatisfy { $0 == 0 })
    }

    @Test func replacingAWindowAfterADistantJumpDoesNotInsertSilence() throws {
        let bank = ScratchSampleBank()
        let first = try #require(bank.beginWrite())
        bank.slots[first].samples.update(repeating: 0.4, count: ScratchSampleBank.capacity * 2)
        bank.publish(slot: first, start: 0, count: ScratchSampleBank.capacity)
        let control = ScratchAudioControl()
        let renderer = ScratchAudioRenderer(control: control, bank: bank)
        control.active.store(true, ordering: .releasing)
        control.update(time: 2, rate: 1, hostTime: 10)
        _ = render(renderer, count: 1024, hostTime: 10)
        control.update(time: 20, rate: 1, hostTime: 10.02)
        let bridge = render(renderer, count: 256, hostTime: 10.02)
        let second = try #require(bank.beginWrite())
        bank.slots[second].samples.update(repeating: 0.6, count: ScratchSampleBank.capacity * 2)
        bank.publish(slot: second, start: 16 * 48_000, count: ScratchSampleBank.capacity)
        let replacement = render(renderer, count: 512, hostTime: 10.025)
        #expect(replacement.left.allSatisfy { $0 > 0.1 })
        #expect(abs(replacement.left[0] - bridge.left.last!) < 0.01)
    }

    @Test func slowMovementIsQuieterAndGainChangesStayContinuous() throws {
        let bank = ScratchSampleBank()
        let slot = try #require(bank.beginWrite())
        bank.slots[slot].samples.update(repeating: 0.4, count: ScratchSampleBank.capacity * 2)
        bank.publish(slot: slot, start: 0, count: ScratchSampleBank.capacity)
        let control = ScratchAudioControl()
        let renderer = ScratchAudioRenderer(control: control, bank: bank)
        control.active.store(true, ordering: .releasing)
        control.update(time: 2, rate: 1, hostTime: 10)
        let normal = render(renderer, count: 4096, hostTime: 10).left
        let slowHostTime = 10 + 4096 / ScratchSampleBank.sampleRate
        control.update(time: 2.0715, rate: 0.1, hostTime: slowHostTime)
        let slow = render(renderer, count: 4096, hostTime: slowHostTime).left
        #expect(abs(normal.last! - 0.34) < 0.001)
        #expect(abs(slow.last! - 0.034) < 0.001)
        let transition = [normal.last!] + slow
        #expect(zip(transition, transition.dropFirst()).allSatisfy { abs($0 - $1) < 0.001 })
        control.active.store(false, ordering: .releasing)
        let stopped = render(renderer, count: 1024, hostTime: slowHostTime + 4096 / ScratchSampleBank.sampleRate).left
        #expect(stopped.suffix(500).allSatisfy { $0 == 0 })
    }

    @Test func slowScrubPositionUpdatesKeepAudioContinuous() throws {
        let bank = ScratchSampleBank()
        let slot = try #require(bank.beginWrite())
        let frames = 3 * Int(ScratchSampleBank.sampleRate)
        for frame in 0..<frames {
            let value = Float(sin(Double(frame) * 2 * .pi / 48))
            bank.slots[slot].samples[frame * 2] = value
            bank.slots[slot].samples[frame * 2 + 1] = value
        }
        bank.publish(slot: slot, start: 0, count: frames)
        let control = ScratchAudioControl()
        let renderer = ScratchAudioRenderer(control: control, bank: bank)
        control.active.store(true, ordering: .releasing)
        control.update(time: 2, rate: 0.05, hostTime: 10)
        let before = render(renderer, count: 960, hostTime: 10).left
        control.update(time: 2.0015, rate: 0.05, hostTime: 10.02)
        let after = render(renderer, count: 960, hostTime: 10.02).left
        control.update(time: 2.002, rate: -0.05, hostTime: 10.04)
        let reversed = render(renderer, count: 2400, hostTime: 10.04).left
        let transition = [try #require(before.last)] + after + reversed
        #expect(zip(transition, transition.dropFirst()).allSatisfy { abs($0 - $1) < 0.001 })
        #expect(reversed.dropFirst(300).prefix(900).filter { abs($0) < 0.002 }.count > 40)
        #expect(reversed.suffix(500).contains { abs($0) > 0.015 })
    }

    private func render(_ renderer: ScratchAudioRenderer, count: Int, hostTime: Double) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                renderer.render(count: count, left: l.baseAddress!, right: r.baseAddress!, hostTime: hostTime)
            }
        }
        return (left, right)
    }

    private func makeConstantAudio(value: Float) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-audio-\(UUID()).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        buffer.floatChannelData![0].update(repeating: value, count: 48_000)
        buffer.floatChannelData![1].update(repeating: value, count: 48_000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
