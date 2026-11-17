@preconcurrency import AVFoundation
import Foundation
import os
import QuartzCore
import Synchronization

struct ScratchVelocity {
    private var previousTime: Double?
    private var previousHost: Double = 0
    private(set) var rate: Double = 0

    mutating func reset(time: Double, hostTime: Double) {
        previousTime = time
        previousHost = hostTime
        rate = 0
    }

    mutating func update(time: Double, hostTime: Double) -> Double {
        guard time.isFinite, hostTime.isFinite else { return rate }
        let elapsed = hostTime - previousHost
        // Scroll callbacks can arrive in a batch within the same millisecond.
        // Accumulate that displacement until there is a measurable interval.
        if previousTime != nil, elapsed >= 0, elapsed <= 0.001 { return rate }
        defer { previousTime = time; previousHost = hostTime }
        guard let previousTime, previousTime.isFinite, elapsed > 0, elapsed < 0.2 else { rate = 0; return 0 }
        let raw = min(max((time - previousTime) / elapsed, -8), 8)
        // Direction reversals must sound immediately, rather than gliding
        // through the previous direction for several UI events.
        let blend = 1 - exp(-elapsed / 0.025)
        rate = raw * rate < 0 ? raw : rate + (raw - rate) * blend
        return rate
    }
}

final class ScratchAudioControl: @unchecked Sendable {
    let active = Atomic<Bool>(false)
    let position = Atomic<Double>(0)
    let rate = Atomic<Double>(0)
    let updatedAt = Atomic<Double>(0)

    func update(time: Double, rate: Double, hostTime: Double) {
        position.store(time, ordering: .relaxed)
        self.rate.store(rate, ordering: .relaxed)
        updatedAt.store(hostTime, ordering: .releasing)
    }
}

/// Two fixed PCM windows: the decoder writes only an unborrowed inactive
/// window. The audio callback never allocates, waits, reads files, or decodes.
final class ScratchSampleBank: @unchecked Sendable {
    static let sampleRate: Double = 48_000
    static let channels = 2
    static let capacity = 8 * 48_000

    final class Slot {
        let samples: UnsafeMutablePointer<Float>
        let start = Atomic<Int64>(0)
        let count = Atomic<Int>(0)
        let generation = Atomic<Int>(0)
        init() {
            samples = .allocate(capacity: capacity * channels)
            samples.initialize(repeating: 0, count: capacity * channels)
        }
        deinit { samples.deinitialize(count: capacity * channels); samples.deallocate() }
    }
    struct Window {
        let samples: UnsafePointer<Float>
        let start: Int64
        let count: Int
        let generation: Int

        func sample(at position: Double, channel: Int) -> Float {
            let local = position - Double(start)
            guard local.isFinite, local >= 0, local < Double(count - 1) else { return 0 }
            let index = Int(local)
            let fraction = Float(local - Double(index))
            let a = samples[index * 2 + channel]
            let b = samples[(index + 1) * 2 + channel]
            return a + (b - a) * fraction
        }
    }
    let slots = [Slot(), Slot()]
    let generation = Atomic<Int>(0)
    private let published = Atomic<Int>(-1)
    private let borrowed = Atomic<Int>(-1)

    func beginWrite(clearingSamples: Bool = true) -> Int? {
        let slot = published.load(ordering: .sequentiallyConsistent) == 0 ? 1 : 0
        guard borrowed.load(ordering: .sequentiallyConsistent) != slot else { return nil }
        if clearingSamples { slots[slot].samples.update(repeating: 0, count: Self.capacity * 2) }
        return slot
    }

    func publish(slot: Int, start: Int64, count: Int, generation: Int = 0) {
        guard self.generation.load(ordering: .acquiring) == generation else { return }
        slots[slot].start.store(start, ordering: .relaxed)
        slots[slot].count.store(count, ordering: .relaxed)
        slots[slot].generation.store(generation, ordering: .relaxed)
        published.store(slot, ordering: .sequentiallyConsistent)
    }

    func covers(time: Double, rate: Double, duration: Double) -> Bool {
        let slot = published.load(ordering: .sequentiallyConsistent)
        guard slot >= 0, slots[slot].generation.load(ordering: .relaxed) == generation.load(ordering: .acquiring) else {
            return false
        }
        let start = Double(slots[slot].start.load(ordering: .relaxed)) / Self.sampleRate
        let end = start + Double(slots[slot].count.load(ordering: .relaxed)) / Self.sampleRate
        let margin = min(max(0.2, abs(rate) * 0.06), 0.45)
        guard time >= start, time < end - 1 / Self.sampleRate else { return false }
        return rate >= 0 ? time + margin < end || end >= duration - 0.001
            : time - margin > start || start <= 0
    }

    func clear() { published.store(-1, ordering: .sequentiallyConsistent) }

    func borrow() -> Window? {
        let slot = published.load(ordering: .sequentiallyConsistent)
        guard slot >= 0 else { return nil }
        borrowed.store(slot, ordering: .sequentiallyConsistent)
        let slotGeneration = slots[slot].generation.load(ordering: .relaxed)
        guard published.load(ordering: .sequentiallyConsistent) == slot,
            slotGeneration == generation.load(ordering: .acquiring) else {
            borrowed.store(-1, ordering: .sequentiallyConsistent)
            return nil
        }
        return Window(samples: UnsafePointer(slots[slot].samples),
                      start: slots[slot].start.load(ordering: .relaxed),
                      count: slots[slot].count.load(ordering: .relaxed),
                      generation: slotGeneration)
    }

    func release() { borrowed.store(-1, ordering: .sequentiallyConsistent) }
}

final class ScratchAudioRenderer: @unchecked Sendable {
    let control: ScratchAudioControl
    let bank: ScratchSampleBank
    private var lastUpdate = -Double.infinity
    private var windowGeneration: Int?
    private var position: Double = 0
    private var trackingError: Double = 0
    private var speed: Double = 0
    private var gain: Float = 0
    private var oldPosition: Double = 0
    private var oldSpeed: Double = 0
    private var crossfade = 0
    private var missingSince: Double?
    private var lastDryLeft: Float = 0
    private var lastDryRight: Float = 0
    private var heldLeft: Float = 0
    private var heldRight: Float = 0
    private let fadeFrames = 384 // 8 ms for seeks that break the continuous trajectory.

    init(control: ScratchAudioControl, bank: ScratchSampleBank) {
        self.control = control
        self.bank = bank
    }

    func makeSourceNode() -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: ScratchSampleBank.sampleRate, channels: 2)!
        return AVAudioSourceNode(format: format) { [self] _, _, count, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard list.count == 2,
                let left = list[0].mData?.assumingMemoryBound(to: Float.self),
                let right = list[1].mData?.assumingMemoryBound(to: Float.self) else {
                for buffer in list { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                return noErr
            }
            render(count: Int(count), left: left, right: right, hostTime: CACurrentMediaTime())
            return noErr
        }
    }

    func render(count: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, hostTime: Double) {
        guard let window = bank.borrow() else {
            left.update(repeating: 0, count: count)
            right.update(repeating: 0, count: count)
            return
        }
        defer { bank.release() }
        if windowGeneration != window.generation {
            windowGeneration = window.generation
            lastUpdate = -Double.infinity
            gain = 0
            crossfade = 0
            speed = 0
            position = 0
            trackingError = 0
            missingSince = nil
            lastDryLeft = 0
            lastDryRight = 0
        }
        let event = control.updatedAt.load(ordering: .acquiring)
        let requestedRate = control.rate.load(ordering: .relaxed)
        let age = max(hostTime - event, 0)
        let active = control.active.load(ordering: .relaxed) && age < 0.08
        let targetRate = active ? requestedRate : 0
        let desiredPosition = control.position.load(ordering: .relaxed) * ScratchSampleBank.sampleRate
            + min(age, 0.02) * requestedRate * ScratchSampleBank.sampleRate
        let hasTarget = desiredPosition >= Double(window.start)
            && desiredPosition < Double(window.start) + Double(window.count - 1)
        if hasTarget {
            missingSince = nil
            if event != lastUpdate {
                let error = desiredPosition - position
                let continuous = lastUpdate.isFinite && abs(error) < 0.015 * ScratchSampleBank.sampleRate
                if continuous {
                    trackingError = error
                } else {
                    trackingError = 0
                    oldPosition = position
                    oldSpeed = speed
                    heldLeft = lastDryLeft
                    heldRight = lastDryRight
                    position = desiredPosition
                    crossfade = fadeFrames
                }
                lastUpdate = event
            }
        } else if missingSince == nil {
            missingSince = hostTime
        }
        if !active || !hasTarget { trackingError = 0 }
        // Bridge a very short refill with the existing trajectory, then fade.
        // Never hard-jump to unread PCM or replay stale content indefinitely.
        let refillGain = missingSince.map { Float(max(0, 1 - (hostTime - $0) / 0.02)) } ?? 1
        // Feed position tracking through the same speed smoothing as gesture velocity.
        // At a reversal the read head passes through zero speed on the same waveform.
        let correctionLimit = abs(targetRate) * 0.35
        let slowMotion = max(abs(speed), abs(targetRate)) < 0.25
        let speedBlend = slowMotion && active ? 0.00085 : 0.0015
        for frame in 0..<count {
            let correction = min(max(trackingError / 960, -correctionLimit), correctionLimit)
            trackingError -= correction
            speed += (targetRate + correction - speed) * speedBlend
            // Fade through a stop or reversal using the actual read speed.
            let movementGain = Float(min(abs(speed), 1))
            let targetGain = active ? 0.85 * movementGain * refillGain : 0
            gain += min(max(targetGain - gain, -1 / 480), 1 / 480)
            var l = window.sample(at: position, channel: 0)
            var r = window.sample(at: position, channel: 1)
            if crossfade > 0 {
                let remaining = Float(crossfade) / Float(fadeFrames)
                let weight = remaining * remaining * (3 - 2 * remaining)
                let hasOldPosition = oldPosition >= Double(window.start)
                    && oldPosition < Double(window.start) + Double(window.count - 1)
                let oldLeft = hasOldPosition ? window.sample(at: oldPosition, channel: 0) : heldLeft
                let oldRight = hasOldPosition ? window.sample(at: oldPosition, channel: 1) : heldRight
                l = l * (1 - weight) + oldLeft * weight
                r = r * (1 - weight) + oldRight * weight
                oldPosition += oldSpeed
                crossfade -= 1
            }
            lastDryLeft = l
            lastDryRight = r
            left[frame] = min(max(l * gain, -1), 1)
            right[frame] = min(max(r * gain, -1), 1)
            position += speed
        }
    }
}

private final class ScratchAudioWorker: @unchecked Sendable {
    private struct Demand {
        var generation = 0
        var center: Double = 0
        var needsWindow = false
        var windowQueued = false
        var cache: ScratchTimelineCache?
    }

    private let queue = DispatchQueue(label: "com.moysoft.motionary.scratch-audio", qos: .userInitiated)
    private let engineQueue = DispatchQueue(label: "com.moysoft.motionary.scratch-engine", qos: .userInitiated)
    private let cacheQueue = DispatchQueue(label: "com.moysoft.motionary.scratch-pcm-cache", qos: .utility)
    private let demand = OSAllocatedUnfairLock(initialState: Demand())
    let control = ScratchAudioControl()
    let bank = ScratchSampleBank()
    private var engine: AVAudioEngine?
    private var node: AVAudioSourceNode?
    private var asset: AVComposition?
    private var tracks: [AVAssetTrack] = []
    private var audioMix: AVAudioMix?
    private var duration: Double = 0
    private var installedGeneration: Int?

    func configure(asset: AVComposition, audioMix: AVAudioMix?, duration: Double, around time: Double, generation: Int) {
        invalidate(generation: generation, around: time)
        engineQueue.async { [self] in
            if engine == nil { makeEngine() }
            startEngine()
        }
        queue.async { [self] in
            guard bank.generation.load(ordering: .acquiring) == generation else { return }
            // Use a separate audio-only graph so AVAssetReader never opens
            // the composition currently supplying video frames to AVPlayer.
            let scratchAsset = Self.audioOnlyCopy(of: asset) ?? asset
            self.asset = scratchAsset
            self.audioMix = audioMix
            self.duration = duration
            tracks = scratchAsset.tracks(withMediaType: .audio)
            installedGeneration = generation
            let cache = ScratchTimelineCache(asset: scratchAsset, tracks: tracks, audioMix: audioMix, duration: duration,
                                             queue: cacheQueue) { [weak self] in
                self?.cacheAdvanced(generation: generation, duration: duration)
            }
            let installed = demand.withLock { state in
                guard state.generation == generation else { return false }
                state.cache = cache
                return true
            }
            guard installed else { cache.cancel(); return }
            updateDemand(generation: generation)
        }
    }

    private static func audioOnlyCopy(of source: AVComposition) -> AVComposition? {
        guard let copy = source.mutableCopy() as? AVMutableComposition else { return nil }
        for track in copy.tracks where track.mediaType != .audio {
            copy.removeTrack(track)
        }
        let originalIDs = source.tracks(withMediaType: .audio).map(\.trackID)
        return copy.tracks.map(\.trackID) == originalIDs ? copy : nil
    }

    func invalidate(generation: Int, around time: Double) {
        let cache = demand.withLock { state in
            bank.generation.store(generation, ordering: .releasing)
            state.generation = generation
            state.center = time
            state.needsWindow = false
            let cache = state.cache
            state.cache = nil
            return cache
        }
        cache?.cancel()
    }

    func updateDemand(around time: Double? = nil, generation: Int, needsWindow: Bool = true) {
        let shouldQueue = demand.withLock { state in
            guard state.generation == generation else { return false }
            if let time {
                state.center = time
                state.needsWindow = needsWindow
            } else {
                state.needsWindow = state.needsWindow || needsWindow
            }
            guard state.needsWindow, !state.windowQueued else { return false }
            state.windowQueued = true
            return true
        }
        if shouldQueue { queueLatestWindow() }
    }

    private func cacheAdvanced(generation: Int, duration: Double) {
        let shouldQueue = demand.withLock { state in
            guard state.generation == generation, state.cache?.contains(state.center) == true,
                !bank.covers(time: state.center, rate: control.rate.load(ordering: .relaxed), duration: duration)
            else { return false }
            state.needsWindow = true
            guard !state.windowQueued else { return false }
            state.windowQueued = true
            return true
        }
        if shouldQueue { queueLatestWindow() }
    }

    private func queueLatestWindow() {
        queue.async { [self] in
            let request = demand.withLock { state -> (Int, Double, ScratchTimelineCache?)? in
                guard state.needsWindow else { return nil }
                state.needsWindow = false
                return (state.generation, state.center, state.cache)
            }
            if let (generation, center, cache) = request {
                readWindow(around: center, generation: generation, cache: cache)
            }
            let needsNext = demand.withLock { state in
                if !state.needsWindow { state.windowQueued = false }
                return state.needsWindow
            }
            if needsNext { queueLatestWindow() }
        }
    }

    func start() { engineQueue.async { [self] in startEngine() } }
    func stop() {
        control.active.store(false, ordering: .releasing)
        engineQueue.asyncAfter(deadline: .now() + .milliseconds(20)) { [self] in
            if !control.active.load(ordering: .acquiring) { engine?.pause() }
        }
    }

    func shutdown() {
        stop()
        invalidate(generation: bank.generation.load(ordering: .acquiring) &+ 1, around: 0)
        engineQueue.async { [self] in
            engine?.stop()
            if let node { engine?.detach(node) }
            engine = nil
            node = nil
        }
        queue.async { [self] in
            asset = nil
            tracks = []
            audioMix = nil
            bank.clear()
        }
    }

    private func makeEngine() {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: ScratchSampleBank.sampleRate, channels: 2)!
        let renderer = ScratchAudioRenderer(control: control, bank: bank)
        let node = renderer.makeSourceNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        self.engine = engine
        self.node = node
    }

    private func startEngine() {
        guard control.active.load(ordering: .acquiring), let engine, !engine.isRunning else { return }
        do { try engine.start() }
        catch { AppLogger.media.warning("Scratch audio unavailable: \(error.localizedDescription, privacy: .public)") }
    }

    private func readWindow(around time: Double, generation: Int, cache: ScratchTimelineCache?) {
        guard bank.generation.load(ordering: .acquiring) == generation,
            installedGeneration == generation, let asset, !tracks.isEmpty else { return }
        let center = min(max(time, 0), max(0, duration - 2 / ScratchSampleBank.sampleRate))
        let speed = control.rate.load(ordering: .relaxed)
        guard !bank.covers(time: center, rate: speed, duration: duration) else { return }
        guard let slot = bank.beginWrite(clearingSamples: false) else {
            queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in
                self?.updateDemand(generation: generation)
            }
            return
        }
        let coversLatest: (Int64, Int) -> Bool = { [self] start, count in
            demand.withLock {
                let latest = min(max($0.center, 0), max(0, duration - 2 / ScratchSampleBank.sampleRate))
                    * ScratchSampleBank.sampleRate
                return $0.generation == generation && latest >= Double(start) && latest < Double(start) + Double(count - 1)
            }
        }
        if cache?.fill(bank: bank, slot: slot, around: center, rate: speed,
                       generation: generation, shouldPublish: coversLatest) == true { return }
        // Publish a short audible window first. Waiting for a complete eight
        // seconds was the cause of gaps after large, fast timeline jumps.
        let windowLength = 0.55 + min(abs(speed) * 0.075, 0.6)
        let leading = speed < 0 ? windowLength * 0.75 : windowLength * 0.25
        ScratchWindowDecoder.read(asset: asset, tracks: tracks, audioMix: audioMix,
                                  duration: duration, around: center, bank: bank, slot: slot,
                                  windowLength: windowLength, leading: leading, generation: generation,
                                  shouldPublish: coversLatest) { [self] in
            guard bank.generation.load(ordering: .acquiring) == generation else { return false }
            // Let nearby reads finish during continuous motion. A jump far
            // outside this window should immediately go back to the cache.
            let latest = demand.withLock { $0.center }
            if abs(latest - center) <= windowLength { return true }
            return cache?.contains(latest) != true
                && !bank.covers(time: latest, rate: control.rate.load(ordering: .relaxed), duration: duration)
        }
    }
}

enum ScratchWindowDecoder {
    static let bytesPerFrame = MemoryLayout<Float>.size * ScratchSampleBank.channels
    private static let sampleRate = Int32(ScratchSampleBank.sampleRate)

    private static func audibleTracks(_ tracks: [AVAssetTrack], in range: CMTimeRange) -> [AVAssetTrack] {
        tracks.filter { track in
            guard let track = track as? AVCompositionTrack else { return true }
            return track.segments.contains {
                !$0.isEmpty && $0.timeMapping.target.intersection(range).duration > .zero
            }
        }
    }

    private static func mix(_ mix: AVAudioMix?, for tracks: [AVAssetTrack]) -> AVAudioMix? {
        guard let mix else { return nil }
        let ids = Set(tracks.map(\.trackID))
        let parameters = mix.inputParameters
        let matching = parameters.filter { ids.contains($0.trackID) }
        guard matching.count != parameters.count else { return mix }
        let result = AVMutableAudioMix()
        result.inputParameters = matching
        return result
    }

    static func read(asset: AVAsset, tracks: [AVAssetTrack], audioMix: AVAudioMix?, duration: Double,
                     around time: Double, bank: ScratchSampleBank, slot: Int,
                     windowLength: Double = 8, leading: Double = 4,
                     generation: Int = 0,
                     shouldPublish: (Int64, Int) -> Bool = { _, _ in true },
                     shouldContinue: () -> Bool) {
        guard time.isFinite, duration.isFinite else { return }
        let start = max(0, time - leading)
        let length = min(windowLength, duration - start)
        guard length > 0 else { return }
        let startFrame = Int64((start * ScratchSampleBank.sampleRate).rounded())
        let count = min(ScratchSampleBank.capacity, Int(length * ScratchSampleBank.sampleRate))
        guard count > 1 else { return }
        let samples = bank.slots[slot].samples
        samples.update(repeating: 0, count: count * ScratchSampleBank.channels)
        do {
            // Give the codecs and time-pitch algorithm context before a
            // random seek. Copy only the requested PCM at its timeline PTS.
            let complete = try readPCM(asset: asset, tracks: tracks, audioMix: audioMix,
                                       start: startFrame, end: startFrame + Int64(count),
                                       preroll: Int64(sampleRate) / 5, shouldContinue: shouldContinue) {
                block, skip, position, frames in
                let destination = samples.advanced(by: Int(position - startFrame) * ScratchSampleBank.channels)
                try copy(block, skip: skip, frames: frames, to: destination)
            }
            if complete, shouldPublish(startFrame, count) {
                bank.publish(slot: slot, start: startFrame, count: count, generation: generation)
            }
        } catch {
            AppLogger.media.warning("Scratch audio preparation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func readPCM(asset: AVAsset, tracks: [AVAssetTrack], audioMix: AVAudioMix?,
                        start: Int64, end: Int64, preroll: Int64 = 0, shouldContinue: () -> Bool,
                        consume: (CMBlockBuffer, Int, Int64, Int) throws -> Void) throws -> Bool {
        guard shouldContinue() else { return false }
        let decodeStart = max(0, start - preroll)
        let range = CMTimeRange(start: CMTime(value: decodeStart, timescale: sampleRate),
                                end: CMTime(value: end, timescale: sampleRate))
        let activeTracks = audibleTracks(tracks, in: range)
        guard !activeTracks.isEmpty else { return shouldContinue() }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: activeTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: ScratchSampleBank.sampleRate,
            AVNumberOfChannelsKey: ScratchSampleBank.channels, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix(audioMix, for: activeTracks)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        reader.timeRange = range
        guard reader.startReading() else { return false }
        defer { reader.cancelReading() }
        while shouldContinue() {
            let hadSample = try autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return false }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                guard time.isNumeric, let block = CMSampleBufferGetDataBuffer(sample) else { return true }
                let sampleStart = time.convertScale(sampleRate, method: .roundHalfAwayFromZero).value
                let position = max(start, sampleStart)
                let skip = Int(position - sampleStart)
                let frames = min(CMSampleBufferGetNumSamples(sample) - skip, Int(end - position))
                guard frames > 0 else { return true }
                try consume(block, skip, position, frames)
                return true
            }
            if !hadSample { break }
        }
        if reader.status == .failed, let error = reader.error { throw error }
        return shouldContinue() && reader.status == .completed
    }

    static func copy(_ block: CMBlockBuffer, skip: Int, frames: Int, to destination: UnsafeMutableRawPointer) throws {
        let status = CMBlockBufferCopyDataBytes(block, atOffset: skip * bytesPerFrame, dataLength: frames * bytesPerFrame,
                                               destination: destination)
        guard status == kCMBlockBufferNoErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

@MainActor
final class TimelineScratchAudio {
    private var worker: ScratchAudioWorker?
    private var assetIdentity: ObjectIdentifier?
    private var mixIdentity: ObjectIdentifier?
    private var generation = 0
    private var timelineDuration: Double = 0
    private var velocity = ScratchVelocity()
    private var isGestureActive = false
    private var gestureTime: Double = 0
    private var gestureHostTime: Double = 0

    deinit { worker?.shutdown() }

    func prepare(item: AVPlayerItem?, duration: Double, at time: Double) {
        guard AppPreferences.djScratching else {
            if worker != nil { shutdown() }
            return
        }
        guard let composition = item?.asset as? AVComposition, let item,
            composition.tracks.contains(where: { $0.mediaType == .audio }) else { invalidate(); return }
        let identity = ObjectIdentifier(composition)
        let audioMix = item.audioMix
        let mix = audioMix.map(ObjectIdentifier.init)
        guard identity != assetIdentity || mix != mixIdentity || duration != timelineDuration else { return }
        assetIdentity = identity
        mixIdentity = mix
        generation += 1
        timelineDuration = duration
        let worker = self.worker ?? ScratchAudioWorker()
        self.worker = worker
        worker.configure(asset: composition, audioMix: audioMix, duration: duration,
                         around: isGestureActive ? gestureTime : time, generation: generation)
        if isGestureActive {
            worker.control.update(time: playableScratchTime(gestureTime), rate: velocity.rate, hostTime: gestureHostTime)
            worker.control.active.store(true, ordering: .releasing)
            worker.start()
        }
    }

    /// Stop using the previous item or mix as soon as an audio edit takes effect.
    /// An active gesture can resume at its latest point when prepare installs the new graph.
    func invalidate() {
        guard assetIdentity != nil else { return }
        assetIdentity = nil
        mixIdentity = nil
        generation &+= 1
        worker?.invalidate(generation: generation, around: gestureTime)
    }

    func begin(item: AVPlayerItem?, duration: Double, at time: Double) {
        guard AppPreferences.djScratching else { shutdown(); return }
        let now = CACurrentMediaTime()
        isGestureActive = true
        gestureTime = time
        gestureHostTime = now
        velocity.reset(time: time, hostTime: now)
        prepare(item: item, duration: duration, at: time)
        guard assetIdentity != nil, let worker else { return }
        let position = playableScratchTime(time)
        worker.control.update(time: position, rate: 0, hostTime: now)
        worker.control.active.store(true, ordering: .releasing)
        worker.start()
        worker.updateDemand(around: position, generation: generation, needsWindow: !hasPreparedAudio(at: time))
    }

    func update(to time: Double) {
        guard AppPreferences.djScratching, isGestureActive else { end(); return }
        gestureTime = time
        let now = CACurrentMediaTime()
        gestureHostTime = now
        let rate = velocity.update(time: time, hostTime: now)
        guard assetIdentity != nil, let worker else { return }
        let position = playableScratchTime(time)
        worker.control.update(time: position, rate: rate, hostTime: now)
        worker.updateDemand(around: position, generation: generation, needsWindow: !hasPreparedAudio(at: time))
    }

    func hasPreparedAudio(at time: Double) -> Bool {
        guard assetIdentity != nil, let worker else { return false }
        return worker.bank.covers(time: playableScratchTime(time), rate: velocity.rate, duration: timelineDuration)
    }

    private func playableScratchTime(_ time: Double) -> Double {
        min(max(time, 0), max(0, timelineDuration - 2 / ScratchSampleBank.sampleRate))
    }

    func end() {
        isGestureActive = false
        worker?.stop()
    }

    func shutdown() {
        isGestureActive = false
        worker?.shutdown()
        worker = nil
        assetIdentity = nil
        mixIdentity = nil
        generation += 1
    }
}
