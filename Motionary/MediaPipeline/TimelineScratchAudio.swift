@preconcurrency import AVFoundation
import Foundation
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
        defer { previousTime = time; previousHost = hostTime }
        guard time.isFinite, hostTime.isFinite, let previousTime else { rate = 0; return 0 }
        let elapsed = hostTime - previousHost
        guard previousTime.isFinite, elapsed > 0.001, elapsed < 0.2 else { rate = 0; return 0 }
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
    private let published = Atomic<Int>(-1)
    private let borrowed = Atomic<Int>(-1)

    func beginWrite() -> Int? {
        let slot = published.load(ordering: .sequentiallyConsistent) == 0 ? 1 : 0
        guard borrowed.load(ordering: .sequentiallyConsistent) != slot else { return nil }
        slots[slot].samples.update(repeating: 0, count: Self.capacity * 2)
        return slot
    }

    func publish(slot: Int, start: Int64, count: Int) {
        slots[slot].start.store(start, ordering: .relaxed)
        slots[slot].count.store(count, ordering: .relaxed)
        published.store(slot, ordering: .sequentiallyConsistent)
    }

    func covers(time: Double, rate: Double, duration: Double) -> Bool {
        let slot = published.load(ordering: .sequentiallyConsistent)
        guard slot >= 0 else { return false }
        let start = Double(slots[slot].start.load(ordering: .relaxed)) / Self.sampleRate
        let end = start + Double(slots[slot].count.load(ordering: .relaxed)) / Self.sampleRate
        let margin = max(0.25, abs(rate) * 0.25)
        guard time >= start, time < end - 1 / Self.sampleRate else { return false }
        return rate >= 0 ? time + margin < end || end >= duration - 0.001
            : time - margin > start || start <= 0
    }

    func clear() { published.store(-1, ordering: .sequentiallyConsistent) }

    func borrow() -> Window? {
        let slot = published.load(ordering: .sequentiallyConsistent)
        guard slot >= 0 else { return nil }
        borrowed.store(slot, ordering: .sequentiallyConsistent)
        guard published.load(ordering: .sequentiallyConsistent) == slot else {
            borrowed.store(-1, ordering: .sequentiallyConsistent)
            return nil
        }
        return Window(samples: UnsafePointer(slots[slot].samples),
                      start: slots[slot].start.load(ordering: .relaxed),
                      count: slots[slot].count.load(ordering: .relaxed))
    }

    func release() { borrowed.store(-1, ordering: .sequentiallyConsistent) }
}

final class ScratchAudioRenderer: @unchecked Sendable {
    let control: ScratchAudioControl
    let bank: ScratchSampleBank
    private var lastUpdate = -Double.infinity
    private var position: Double = 0
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
    private let fadeFrames = 384 // 8 ms, softens jumps without masking quick reversals.

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
                oldPosition = position
                oldSpeed = speed
                heldLeft = lastDryLeft
                heldRight = lastDryRight
                position = desiredPosition
                crossfade = fadeFrames
                lastUpdate = event
            }
        } else if missingSince == nil {
            missingSince = hostTime
        }
        // Bridge a very short refill with the existing trajectory, then fade.
        // Never hard-jump to unread PCM or replay stale content indefinitely.
        let refillGain = missingSince.map { Float(max(0, 1 - (hostTime - $0) / 0.02)) } ?? 1
        // Slow hand motion should be quiet, reaching the existing maximum at 1x.
        let movementGain = Float(min(abs(targetRate), 1))
        let targetGain: Float = active && abs(targetRate) > 0.005
            ? 0.85 * movementGain * refillGain : 0
        for frame in 0..<count {
            speed += (targetRate - speed) * 0.0015
            gain += min(max(targetGain - gain, -1 / 480), 1 / 480)
            var l = window.sample(at: position, channel: 0)
            var r = window.sample(at: position, channel: 1)
            if crossfade > 0 {
                let weight = Float(crossfade) / Float(fadeFrames)
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
    let queue = DispatchQueue(label: "com.moysoft.motionary.scratch-audio", qos: .userInitiated)
    let generation = Atomic<Int>(0)
    let control = ScratchAudioControl()
    let bank = ScratchSampleBank()
    private var engine: AVAudioEngine?
    private var node: AVAudioSourceNode?
    private var asset: AVAsset?
    private var audioMix: AVAudioMix?
    private var duration: Double = 0
    private let windowCenter = Atomic<Double>(0)
    private let windowRequestPending = Atomic<Bool>(false)
    private var timelineCache: ScratchTimelineCache?

    func configure(asset: AVAsset, audioMix: AVAudioMix?, duration: Double, around time: Double, generation: Int) {
        self.generation.store(generation, ordering: .releasing)
        windowCenter.store(time, ordering: .releasing)
        queue.async { [self] in
            guard self.generation.load(ordering: .acquiring) == generation else { return }
            self.asset = asset
            self.audioMix = audioMix
            self.duration = duration
            bank.clear()
            timelineCache?.cancel()
            let tracks = (asset as? AVComposition)?.tracks.filter { $0.mediaType == .audio } ?? []
            timelineCache = ScratchTimelineCache(asset: asset, tracks: tracks, audioMix: audioMix, duration: duration) { [weak self] in
                guard let self else { return }
                let center = self.control.active.load(ordering: .acquiring)
                    ? self.control.position.load(ordering: .relaxed) : self.windowCenter.load(ordering: .acquiring)
                self.requestWindow(around: center, generation: generation)
            }
            if engine == nil { makeEngine() }
            readWindow(around: windowCenter.load(ordering: .acquiring), generation: generation)
            if control.active.load(ordering: .relaxed) { startEngine() }
        }
    }

    func requestWindow(around time: Double, generation: Int) {
        guard self.generation.load(ordering: .acquiring) == generation else { return }
        windowCenter.store(time, ordering: .releasing)
        guard !windowRequestPending.exchange(true, ordering: .acquiringAndReleasing) else { return }
        queue.async { [self] in
            let latest = windowCenter.load(ordering: .acquiring)
            readWindow(around: latest, generation: generation)
            windowRequestPending.store(false, ordering: .releasing)
            let next = windowCenter.load(ordering: .acquiring)
            if next != latest { requestWindow(around: next, generation: self.generation.load(ordering: .acquiring)) }
        }
    }

    func start() { queue.async { [self] in startEngine() } }
    func stop() {
        control.active.store(false, ordering: .releasing)
        queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [self] in
            if !control.active.load(ordering: .acquiring) { engine?.pause() }
        }
    }

    func shutdown() {
        stop()
        generation.wrappingAdd(1, ordering: .releasing)
        queue.async { [self] in
            engine?.stop()
            if let node { engine?.detach(node) }
            engine = nil
            node = nil
            asset = nil
            audioMix = nil
            timelineCache?.cancel()
            timelineCache = nil
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

    private func readWindow(around time: Double, generation: Int) {
        guard self.generation.load(ordering: .acquiring) == generation,
            windowCenter.load(ordering: .acquiring) == time,
            let asset, let composition = asset as? AVComposition else { return }
        let tracks = composition.tracks.filter { $0.mediaType == .audio }
        guard !tracks.isEmpty else { return }
        guard let slot = bank.beginWrite() else {
            queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [self] in
                readWindow(around: time, generation: generation)
            }
            return
        }
        if timelineCache?.fill(bank: bank, slot: slot, around: time) == true { return }
        // Publish a short audible window first. Waiting for a complete eight
        // seconds was the cause of gaps after large, fast timeline jumps.
        let leading = control.rate.load(ordering: .relaxed) < 0 ? 0.8 : 0.2
        let start = max(0, time - leading)
        let end = min(duration, start + 1)
        ScratchWindowDecoder.read(asset: asset, tracks: tracks, audioMix: audioMix,
                                  duration: duration, around: time, bank: bank, slot: slot,
                                  windowLength: 1, leading: leading) { [self] in
            let latest = windowCenter.load(ordering: .acquiring)
            return self.generation.load(ordering: .acquiring) == generation
                && latest >= start && latest < end
        }


    }
}

enum ScratchWindowDecoder {
    static func read(asset: AVAsset, tracks: [AVAssetTrack], audioMix: AVAudioMix?, duration: Double,
                     around time: Double, bank: ScratchSampleBank, slot: Int,
                     windowLength: Double = 8, leading: Double = 4,
                     shouldContinue: () -> Bool) {
        let start = max(0, time - leading)
        let length = min(windowLength, duration - start)
        guard length > 0 else { return }
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: ScratchSampleBank.sampleRate,
                AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
            ])
            output.audioMix = audioMix
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return }
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000),
                                           duration: CMTime(seconds: length, preferredTimescale: 48_000))
            guard reader.startReading() else { return }
            defer { reader.cancelReading() }
            while shouldContinue(),
                let sample = output.copyNextSampleBuffer() {
                autoreleasepool {
                    guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
                    let sampleStart = Int(((CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) - start)
                                           * ScratchSampleBank.sampleRate).rounded())
                    let skip = max(0, -sampleStart)
                    let destination = max(0, sampleStart)
                    let frames = min(CMSampleBufferGetNumSamples(sample) - skip, ScratchSampleBank.capacity - destination)
                    guard frames > 0 else { return }
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: skip * 8, dataLength: frames * 8,
                                                  destination: bank.slots[slot].samples.advanced(by: destination * 2))
                }
            }
            guard shouldContinue(),
                reader.status == .completed else { return }
            bank.publish(slot: slot, start: Int64((start * ScratchSampleBank.sampleRate).rounded()),
                         count: min(ScratchSampleBank.capacity, Int(length * ScratchSampleBank.sampleRate)))
        } catch {
            AppLogger.media.warning("Scratch audio preparation failed: \(error.localizedDescription, privacy: .public)")
        }
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

    deinit { worker?.shutdown() }

    func prepare(item: AVPlayerItem?, duration: Double, at time: Double) {
        guard AppPreferences.djScratching, let item else { return }
        guard let composition = item.asset as? AVComposition,
            composition.tracks.contains(where: { $0.mediaType == .audio }) else { shutdown(); return }
        let identity = ObjectIdentifier(item.asset)
        let mix = item.audioMix.map(ObjectIdentifier.init)
        guard identity != assetIdentity || mix != mixIdentity else { return }
        assetIdentity = identity
        mixIdentity = mix
        generation += 1
        timelineDuration = duration
        let worker = self.worker ?? ScratchAudioWorker()
        self.worker = worker
        worker.configure(asset: item.asset, audioMix: item.audioMix, duration: duration, around: time, generation: generation)
    }

    func begin(item: AVPlayerItem?, duration: Double, at time: Double) {
        guard AppPreferences.djScratching else { shutdown(); return }
        prepare(item: item, duration: duration, at: time)
        guard let worker else { return }
        let now = CACurrentMediaTime()
        velocity.reset(time: time, hostTime: now)
        worker.control.update(time: time, rate: 0, hostTime: now)
        worker.control.active.store(true, ordering: .releasing)
        worker.start()
    }

    func update(to time: Double) {
        guard AppPreferences.djScratching, let worker, worker.control.active.load(ordering: .acquiring) else { end(); return }
        let now = CACurrentMediaTime()
        let rate = velocity.update(time: time, hostTime: now)
        worker.control.update(time: time, rate: rate, hostTime: now)
        if !worker.bank.covers(time: time, rate: rate, duration: timelineDuration) {
            worker.requestWindow(around: time, generation: generation)
        }
    }

    func end() { worker?.stop() }

    func shutdown() {
        worker?.shutdown()
        worker = nil
        assetIdentity = nil
        mixIdentity = nil
        generation += 1
    }
}
