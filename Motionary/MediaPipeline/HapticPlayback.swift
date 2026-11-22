import AVFoundation
import CoreHaptics

protocol HapticPlaybackEngine: AnyObject {
    var currentTime: TimeInterval { get }
    var playsHapticsOnly: Bool { get set }
    var stoppedHandler: CHHapticEngine.StoppedHandler { get set }
    var resetHandler: CHHapticEngine.ResetHandler { get set }
    func start() throws
    func stopPlayback()
    func makeAdvancedPlayer(with pattern: CHHapticPattern) throws -> any CHHapticAdvancedPatternPlayer
}

extension CHHapticEngine: HapticPlaybackEngine {
    func stopPlayback() { stop() }
}

/// Uses the video's clock as the authority while scheduling on the haptic engine's clock.
@MainActor
final class HapticPlayback {
    private static let engineRetryDelay: Duration = .milliseconds(100)

    nonisolated static var isSupported: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    private let makeEngine: () throws -> (any HapticPlaybackEngine)?
    private var engine: (any HapticPlaybackEngine)?
    private var retryEngineAfter: ContinuousClock.Instant?
    private var clockObservation: NSKeyValueObservation?
    private var timeJumpObservation: NSObjectProtocol?
    private var tickTask: Task<Void, Never>?
    private var isAuditioning = false
    private weak var player: AVPlayer?
    private var track = HapticTrack(events: [])
    private var players: [(player: any CHHapticAdvancedPatternPlayer, end: Double)] = []
    private var cursor: Int?
    private var resumeTime: Double?
    private var lastRate: Float = 0

    init(makeEngine: @escaping () throws -> (any HapticPlaybackEngine)? = {
        guard HapticPlayback.isSupported else { return nil }
        return try CHHapticEngine()
    }) {
        self.makeEngine = makeEngine
    }

    func attach(to video: AVPlayer, track: HapticTrack) {
        detach()
        guard !track.events.isEmpty else { return }
        _ = prepareEngine()
        // A failed start can recover once playback begins. Unsupported hardware
        // has no engine to retry.
        guard engine != nil || retryEngineAfter != nil else { return }
        player = video
        self.track = track
        let position = video.currentTime().seconds
        resumeTime = position.isFinite ? position : nil
        clockObservation = video.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateClock() }
        }
        timeJumpObservation = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: video.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.resetSchedule()
                self.resumeTime = self.player?.currentTime().seconds
                self.updateClock()
            }
        }
    }

    func detach() {
        isAuditioning = false
        tickTask?.cancel()
        tickTask = nil
        clockObservation = nil
        if let timeJumpObservation {
            NotificationCenter.default.removeObserver(timeJumpObservation)
        }
        timeJumpObservation = nil
        resetSchedule()
        player = nil
        track = HapticTrack(events: [])
        resumeTime = nil
        retryEngineAfter = nil
        stopEngine()
    }

    @discardableResult
    func audition(_ track: HapticTrack) -> ContinuousClock.Instant? {
        detach()
        guard !track.events.isEmpty, let engine = prepareEngine() else { return nil }
        self.track = track
        isAuditioning = true
        let start = engine.currentTime + 0.045
        let presentationStart = ContinuousClock.now.advanced(by: .milliseconds(45))
        let end = track.events.map(\.end).max() ?? 0
        tickTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.isAuditioning, self.engine === engine {
                let now = engine.currentTime
                let position = now - start
                if position > end + 0.2 {
                    self.stopAudition()
                    return
                }
                self.scheduleEvents(at: position, rate: 1, now: now, engine: engine)
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        return presentationStart
    }

    func stopAudition() {
        if isAuditioning { detach() }
    }

    private func prepareEngine() -> (any HapticPlaybackEngine)? {
        if let engine { return engine }
        if let retryEngineAfter, ContinuousClock.now < retryEngineAfter { return nil }
        do {
            guard let newEngine = try makeEngine() else { return nil }
            newEngine.playsHapticsOnly = true
            let invalidate: @Sendable () -> Void = { [weak self, weak newEngine] in
                Task { @MainActor in
                    guard let self, let newEngine, self.engine === newEngine else { return }
                    self.invalidateEngine()
                }
            }
            newEngine.stoppedHandler = { _ in invalidate() }
            newEngine.resetHandler = invalidate
            try newEngine.start()
            engine = newEngine
            retryEngineAfter = nil
            return newEngine
        } catch {
            retryEngineAfter = ContinuousClock.now.advanced(by: Self.engineRetryDelay)
            AppLogger.lifecycle.debug("Could not start haptic engine: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func invalidateEngine() {
        if isAuditioning {
            stopAudition()
            return
        }
        resetSchedule()
        stopEngine()
    }

    private func stopEngine() {
        let previous = engine
        engine = nil
        previous?.stopPlayback()
    }

    private func resetSchedule() {
        for entry in players { try? entry.player.stop(atTime: CHHapticTimeImmediate) }
        players.removeAll()
        cursor = nil
        lastRate = 0
    }

    private func updateClock() {
        guard let player else { return }
        guard player.timeControlStatus == .playing else {
            tickTask?.cancel()
            tickTask = nil
            if cursor != nil { resumeTime = player.currentTime().seconds }
            resetSchedule()
            return
        }
        tick()
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let player, player.timeControlStatus == .playing, player.rate > 0 else {
            resetSchedule()
            return
        }
        guard let engine = prepareEngine() else { return }
        let position = player.currentTime().seconds
        guard position.isFinite else { return }
        scheduleEvents(at: position, rate: player.rate, now: engine.currentTime, engine: engine)
    }

    private func scheduleEvents(at position: Double, rate: Float, now: Double, engine: any HapticPlaybackEngine) {
        if rate != lastRate {
            resetSchedule()
            lastRate = rate
        }
        // Effects are at most 30 seconds long, so older entries cannot overlap a seek.
        var index = cursor ?? firstEvent(atOrAfter: position - 30.05)
        let earliestImpact = cursor == nil ? max(resumeTime ?? position, position - 0.05) - 0.000_1 : position - 0.025
        while index < track.events.count {
            let event = track.events[index]
            guard event.time <= position + 0.16 * Double(rate) else { break }
            if event.duration > 0 ? event.end > position : event.time >= earliestImpact {
                let offset = max(0, position - event.time)
                let start = now + max(0, event.time - position) / Double(rate)
                do {
                    try schedule(event, offset: offset, rate: rate, engineTime: start, engine: engine)
                } catch {
                    AppLogger.lifecycle.debug("Could not schedule haptics: \(error.localizedDescription, privacy: .public)")
                    switch (error as? CHHapticError)?.code {
                    case .engineNotRunning, .serverInterrupted, .invalidPatternPlayer, .invalidAudioSession:
                        resumeTime = resumeTime ?? position
                        retryEngineAfter = ContinuousClock.now.advanced(by: Self.engineRetryDelay)
                        invalidateEngine()
                        return
                    default:
                        break
                    }
                }
            }
            index += 1
        }
        cursor = index
        resumeTime = nil
        players.removeAll { $0.end + 0.2 < now }
    }

    private func firstEvent(atOrAfter time: Double) -> Int {
        var lower = 0
        var upper = track.events.count
        while lower < upper {
            let midpoint = lower + (upper - lower) / 2
            if track.events[midpoint].time < time {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        return lower
    }

    private func schedule(
        _ event: HapticTrack.Event, offset: Double, rate: Float, engineTime: Double, engine: any HapticPlaybackEngine
    ) throws {
        let first = event.sample(at: offset)
        let duration = max(event.duration - offset, 0)
        let isAutomated = duration > 0 && event.samples.count > 1
        var parameters = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: isAutomated ? 1 : first.intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: isAutomated ? 0 : first.sharpness),
        ]
        if event.duration > 0 {
            parameters.append(CHHapticEventParameter(parameterID: .sustained, value: 1))
        }
        let haptic = CHHapticEvent(
            eventType: event.duration == 0 ? .hapticTransient : .hapticContinuous,
            parameters: parameters, relativeTime: 0, duration: duration
        )
        let curves = isAutomated ? parameterCurves(for: event, initial: first, offset: offset) : []
        let pattern = try CHHapticPattern(events: [haptic], parameterCurves: curves)
        let hapticPlayer = try engine.makeAdvancedPlayer(with: pattern)
        hapticPlayer.playbackRate = rate
        let start = engineTime > engine.currentTime ? engineTime : CHHapticTimeImmediate
        try hapticPlayer.start(atTime: start)
        players.append((hapticPlayer, engineTime + duration / Double(rate)))
    }

    private func parameterCurves(
        for event: HapticTrack.Event, initial: HapticTrack.Sample, offset: Double
    ) -> [CHHapticParameterCurve] {
        let samples = [HapticTrack.Sample(time: offset, intensity: initial.intensity, sharpness: initial.sharpness)]
            + event.samples.filter { $0.time > offset }
        // Neighbouring curves share an endpoint and keep each submission small.
        return stride(from: 0, to: samples.count - 1, by: 15).flatMap { index in
            let points = samples[index...min(index + 15, samples.count - 1)]
            let start = samples[index].time
            return [
                CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: points.map {
                    .init(relativeTime: $0.time - start, value: $0.intensity)
                }, relativeTime: start - offset),
                CHHapticParameterCurve(parameterID: .hapticSharpnessControl, controlPoints: points.map {
                    .init(relativeTime: $0.time - start, value: $0.sharpness)
                }, relativeTime: start - offset),
            ]
        }
    }

}
