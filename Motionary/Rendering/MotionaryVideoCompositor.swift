// Thin AVFoundation adapter for Rendering Engine v2.

@preconcurrency import AVFoundation
import Foundation
import os

extension Notification.Name {
    static let motionaryVideoCompositorPersistentFailure = Notification.Name(
        "MotionaryVideoCompositorPersistentFailure"
    )
    static let motionaryVideoCompositorRenderedFrame = Notification.Name(
        "MotionaryVideoCompositorRenderedFrame"
    )
}

struct RenderContextCachePolicy: Equatable {
    private(set) var renderSize: CGSize?

    mutating func register(renderSize newSize: CGSize) -> Bool {
        defer { renderSize = newSize }
        guard let renderSize else { return false }
        return abs(renderSize.width - newSize.width) > 0.5
            || abs(renderSize.height - newSize.height) > 0.5
    }
}

final class MotionaryVideoCompositor: NSObject, AVVideoCompositing {
    // Retain one GPU output surface. Copying every successful frame into Data
    // forced a CPU readback and full-frame allocation during playback/scrubbing.
    struct LastGoodFrame {
        let pixelBuffer: CVPixelBuffer
        let sessionID: UUID
        let revision: UInt64
        let time: CMTime

        func frame(sessionID: UUID, revision: UInt64, time: CMTime, size: CGSize) -> CVPixelBuffer? {
            guard self.sessionID == sessionID, self.revision == revision,
                time.isNumeric, CMTimeCompare(self.time, time) == 0,
                CVPixelBufferGetWidth(pixelBuffer) == Int(size.width),
                CVPixelBufferGetHeight(pixelBuffer) == Int(size.height)
            else { return nil }
            return pixelBuffer
        }
    }

    final class RequestFinisher: @unchecked Sendable {
        private let lock = NSLock()
        private var didFinish = false
        private var timeoutAction: (() -> Void)?

        @discardableResult
        func finish(_ action: () -> Void) -> Bool {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return false
            }
            didFinish = true
            timeoutAction = nil
            lock.unlock()
            action()
            return true
        }

        func setTimeoutAction(_ action: @escaping () -> Void) {
            lock.lock()
            if !didFinish { timeoutAction = action }
            lock.unlock()
        }

        func timeOut() {
            lock.lock()
            let action = timeoutAction
            lock.unlock()
            if let action { finish(action) }
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didFinish
        }
    }

    private let renderQueue = DispatchQueue(
        label: "com.moysoft.motionary.video-compositor",
        qos: .userInitiated
    )
    private let timeoutQueue = DispatchQueue(
        label: "com.moysoft.motionary.video-compositor.timeout",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private let fallbackLock = NSLock()
    private var requestGeneration: UInt = 0
    private var consecutiveRenderFailures = 0
    private var lastSuccessNotificationAt: CFAbsoluteTime = 0
    private var lastTimeoutLogAt: CFAbsoluteTime = 0
    private var renderContextCachePolicy = RenderContextCachePolicy()
    private var lastGoodFrame: LastGoodFrame?
    private let rendererResult: Result<MetalFrameRenderer, Error>
    private let logger = Logger(subsystem: "com.moysoft.motionary", category: "VideoCompositor")

    override init() {
        rendererResult = Result { try MetalFrameRenderer() }
        super.init()
    }

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_32BGRA,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
        ]
    }

    var supportsWideColorSourceFrames: Bool { false }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        stateLock.lock()
        let shouldPurge = renderContextCachePolicy.register(renderSize: newRenderContext.size)
        stateLock.unlock()
        if shouldPurge, case .success(let renderer) = rendererResult {
            logger.debug(
                "Render size changed to \(newRenderContext.size.width, privacy: .public)x\(newRenderContext.size.height, privacy: .public); purging transient render surfaces."
            )
            clearLastGoodFrame()
            renderer.renderContextDidChange()
        }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction
            as? MotionaryVideoCompositionInstruction
        else {
            request.finish(
                with: NSError(
                    domain: "MotionaryVideoCompositor",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "AVFoundation supplied an incompatible video composition instruction."
                    ]
                )
            )
            return
        }
        // A generation changes only when AVFoundation cancels the current
        // request batch. Advancing it for every interactive frame makes
        // adjacent playback requests cancel one another and can starve the
        // player before a single frame reaches its display layer.
        let generation = currentGeneration()
        renderQueue.async { [weak self] in
            guard let self else {
                request.finishCancelledRequest()
                return
            }
            guard self.isCurrent(generation) else {
                request.finishCancelledRequest()
                return
            }

            autoreleasepool {
                do {
                    if instruction.qualityProfile != .export,
                        let cached = instruction.livePreviewState?.cachedFrame(
                            at: CMTimeGetSeconds(request.compositionTime), sessionID: instruction.renderSessionID),
                        CVPixelBufferGetWidth(cached) == Int(instruction.renderSize.width),
                        CVPixelBufferGetHeight(cached) == Int(instruction.renderSize.height) {
                        self.recordFramePresentation(instruction: instruction, time: request.compositionTime)
                        request.finish(withComposedVideoFrame: cached)
                        return
                    }
                    let renderer = try self.rendererResult.get()
                    guard let destination = request.renderContext.newPixelBuffer() else {
                        throw MetalRenderingError.invalidRenderTarget
                    }
                    if instruction.qualityProfile == .export {
                        // Serialize export GPU work. Three concurrent FP16 effect
                        // graphs can exceed a phone's memory budget at 4K.
                        try renderer.render(
                            plan: RenderPlanCompiler.compile(instruction),
                            compositionTime: request.compositionTime,
                            sourceFrame: { trackID in
                                // AVFoundation can briefly expose an export
                                // request before every required source buffer
                                // is ready. Keep the request alive for a short
                                // bounded window before treating it as a gap.
                                for delay in [0.002, 0.004, 0.008, 0.016] {
                                    if let frame = request.sourceFrame(byTrackID: trackID) {
                                        return frame
                                    }
                                    guard self.isCurrent(generation) else { return nil }
                                    Thread.sleep(forTimeInterval: delay)
                                }
                                return request.sourceFrame(byTrackID: trackID)
                            },
                            destination: destination,
                            isCancelled: { !self.isCurrent(generation) }
                        )
                        request.finish(withComposedVideoFrame: destination)
                        return
                    }
                    let finisher = RequestFinisher()
                    let timeoutMilliseconds = instruction.previewFrameTimeoutMilliseconds
                    finisher.setTimeoutAction { [weak self] in
                        guard let self, self.isCurrent(generation) else {
                            request.finishCancelledRequest()
                            return
                        }
                        self.logFrameTimeoutIfNeeded(
                            instruction: instruction,
                            timeoutMilliseconds: timeoutMilliseconds
                        )
                        self.recordFrameFailure(MetalRenderingError.cancelled, instruction: instruction)
                        // The GPU may still own destination. Never write CPU
                        // fallback pixels into it or hand it to AVPlayer early.
                        if let fallback = self.lastCompleteFrame(for: instruction, at: request.compositionTime) {
                            request.finish(withComposedVideoFrame: fallback)
                        } else {
                            request.finishCancelledRequest()
                        }
                    }
                    // Completed requests must release their pixel buffers immediately;
                    // the delayed timer must not retain every exported frame.
                    self.timeoutQueue.asyncAfter(deadline: .now() + .milliseconds(timeoutMilliseconds)) { [weak finisher] in
                        finisher?.timeOut()
                    }
                    let plan = RenderPlanCompiler.compile(instruction)
                    // Retain only one frame's decoder buffers, never the request.
                    // Reusing these avoids decoding and same-time seek caching
                    // for every paused inspector/canvas sample.
                    var sources: [CMPersistentTrackID: CVPixelBuffer] = [:]
                    for track in request.sourceTrackIDs {
                        let id = track.int32Value
                        if let buffer = request.sourceFrame(byTrackID: id) {
                            sources[id] = buffer
                        }
                    }
                    let cachedSources = sources
                    let renderContext = request.renderContext
                    let frameTime = request.compositionTime
                    renderer.renderAsync(
                        plan: plan,
                        compositionTime: request.compositionTime,
                        sourceFrame: { cachedSources[$0] },
                        destination: destination,
                        isCancelled: { finisher.isFinished || !self.isCurrent(generation) }
                    ) { [weak self] result in
                        guard let self else {
                            finisher.finish {
                                request.finishCancelledRequest()
                            }
                            return
                        }
                        guard self.isCurrent(generation) else {
                            finisher.finish {
                                request.finishCancelledRequest()
                            }
                            return
                        }
                        switch result {
                        case .success:
                            finisher.finish {
                                instruction.livePreviewState?.installPausedFrameRenderer {
                                    [weak self, weak cachedInstruction = instruction] time, sessionID, completion in
                                    guard let self, let instruction = cachedInstruction,
                                        instruction.renderSessionID == sessionID,
                                        time.isFinite, time >= 0,
                                        abs(time - CMTimeGetSeconds(frameTime)) < 0.000_01
                                            || instruction.activeClips(at: time).allSatisfy({
                                                $0.trackID == kCMPersistentTrackID_Invalid
                                            })
                                    else { return false }
                                    let frameRate = CMTimeScale((1 / instruction.frameDuration).rounded())
                                    let frame = time * Double(frameRate)
                                    let targetTime = abs(frame.rounded() - frame) < 0.000_001
                                        ? CMTime(seconds: time, preferredTimescale: frameRate)
                                        : CMTime(seconds: time, preferredTimescale: 600_000)
                                    let cachedGeneration = self.currentGeneration()
                                    let liveFinisher = RequestFinisher()
                                    liveFinisher.setTimeoutAction { completion(nil) }
                                    self.timeoutQueue.asyncAfter(deadline: .now() + .milliseconds(1_200)) {
                                        [weak liveFinisher] in liveFinisher?.timeOut()
                                    }
                                    self.renderQueue.async {
                                        guard !liveFinisher.isFinished,
                                            self.isCurrent(cachedGeneration),
                                            let destination = renderContext.newPixelBuffer()
                                        else { liveFinisher.finish { completion(nil) }; return }
                                        let livePlan = RenderPlanCompiler.compile(instruction)
                                        renderer.renderAsync(
                                            plan: livePlan,
                                            compositionTime: targetTime,
                                            sourceFrame: { cachedSources[$0] },
                                            destination: destination,
                                            isCancelled: {
                                                liveFinisher.isFinished || !self.isCurrent(cachedGeneration)
                                            }
                                        ) { result in
                                            liveFinisher.finish {
                                                if case .success = result {
                                                    instruction.livePreviewState?.cacheFrame(destination, at: time,
                                                        sessionID: sessionID,
                                                        revision: livePlan.livePreviewSnapshot?.revision ?? 0)
                                                    completion(destination)
                                                }
                                                else { completion(nil) }
                                            }
                                        }
                                    }
                                    return true
                                }
                                self.recordSuccessfulFrame(instruction: instruction, time: request.compositionTime,
                                    frame: destination, revision: plan.livePreviewSnapshot?.revision ?? 0)
                                self.storeLastGoodFrame(from: destination, instruction: instruction, time: request.compositionTime,
                                    revision: plan.livePreviewSnapshot?.revision ?? 0)
                                request.finish(withComposedVideoFrame: destination)
                            }
                        case .failure(MetalRenderingError.sourceFrameUnavailable):
                            finisher.finish {
                                if let fallback = self.lastCompleteFrame(for: instruction, at: request.compositionTime) {
                                    request.finish(withComposedVideoFrame: fallback)
                                } else {
                                    request.finishCancelledRequest()
                                }
                            }
                        case .failure(MetalRenderingError.cancelled):
                            finisher.finish {
                                request.finishCancelledRequest()
                            }
                        case .failure(let error):
                            finisher.finish {
                                self.recordFrameFailure(error, instruction: instruction)
                                self.logger.error("Frame rendering failed: \(error.localizedDescription, privacy: .public)")
                                if let fallback = self.lastCompleteFrame(for: instruction, at: request.compositionTime) {
                                    request.finish(withComposedVideoFrame: fallback)
                                } else {
                                    request.finishCancelledRequest()
                                }
                            }
                        }
                    }
                } catch MetalRenderingError.sourceFrameUnavailable {
                    if instruction.qualityProfile == .export {
                        request.finish(with: MetalRenderingError.sourceFrameUnavailable)
                    } else if let fallback = self.lastCompleteFrame(for: instruction, at: request.compositionTime) {
                        request.finish(withComposedVideoFrame: fallback)
                    } else {
                        request.finishCancelledRequest()
                    }
                } catch MetalRenderingError.cancelled {
                    request.finishCancelledRequest()
                } catch {
                    self.recordFrameFailure(error, instruction: instruction)
                    self.logger.error("Frame rendering failed: \(error.localizedDescription, privacy: .public)")
                    if instruction.qualityProfile == .export {
                        request.finish(with: error)
                        return
                    }
                    if let fallback = self.lastCompleteFrame(for: instruction, at: request.compositionTime) {
                        request.finish(withComposedVideoFrame: fallback)
                    } else {
                        request.finishCancelledRequest()
                    }
                }
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        stateLock.lock()
        requestGeneration &+= 1
        stateLock.unlock()
    }

    private func clearLastGoodFrame() {
        fallbackLock.lock()
        lastGoodFrame = nil
        fallbackLock.unlock()
    }

    private func recordSuccessfulFrame(instruction: MotionaryVideoCompositionInstruction, time: CMTime,
                                       frame: CVPixelBuffer, revision: UInt64) {
        instruction.livePreviewState?.cacheFrame(frame, at: CMTimeGetSeconds(time),
            sessionID: instruction.renderSessionID, revision: revision)
        recordFramePresentation(instruction: instruction, time: time)
    }

    private func recordFramePresentation(instruction: MotionaryVideoCompositionInstruction, time: CMTime) {
        let shouldNotify: Bool
        stateLock.lock()
        consecutiveRenderFailures = 0
        let now = CFAbsoluteTimeGetCurrent()
        shouldNotify = instruction.livePreviewState?.usesInteractiveQuality == true
            || now - lastSuccessNotificationAt > 0.25
        if shouldNotify {
            lastSuccessNotificationAt = now
        }
        stateLock.unlock()
        if shouldNotify {
            NotificationCenter.default.post(
                name: .motionaryVideoCompositorRenderedFrame,
                object: self,
                userInfo: ["renderSessionID": instruction.renderSessionID,
                           "compositionTime": CMTimeGetSeconds(time)]
            )
        }
    }

    private func recordFrameFailure(
        _ error: Error,
        instruction: MotionaryVideoCompositionInstruction
    ) {
        stateLock.lock()
        consecutiveRenderFailures += 1
        let shouldNotify = consecutiveRenderFailures == 3 && instruction.qualityProfile != .export
        stateLock.unlock()
        if shouldNotify {
            NotificationCenter.default.post(
                name: .motionaryVideoCompositorPersistentFailure,
                object: self,
                userInfo: ["renderSessionID": instruction.renderSessionID]
            )
        }
    }

    private func logFrameTimeoutIfNeeded(
        instruction: MotionaryVideoCompositionInstruction,
        timeoutMilliseconds: Int
    ) {
        let shouldLog: Bool
        let failureCount: Int
        stateLock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        shouldLog = now - lastTimeoutLogAt > 1
        if shouldLog {
            lastTimeoutLogAt = now
        }
        failureCount = consecutiveRenderFailures + 1
        stateLock.unlock()
        guard shouldLog else { return }
        logger.error(
            "Frame rendering timed out after \(timeoutMilliseconds, privacy: .public)ms; retaining the last valid presentation. clips=\(instruction.clips.count, privacy: .public) failures=\(failureCount, privacy: .public)"
        )
    }

    private func storeLastGoodFrame(from pixelBuffer: CVPixelBuffer,
                                    instruction: MotionaryVideoCompositionInstruction, time: CMTime, revision: UInt64) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return }
        fallbackLock.lock()
        lastGoodFrame = LastGoodFrame(pixelBuffer: pixelBuffer, sessionID: instruction.renderSessionID,
                                      revision: revision, time: time)
        fallbackLock.unlock()
    }

    private func lastCompleteFrame(for instruction: MotionaryVideoCompositionInstruction, at time: CMTime) -> CVPixelBuffer? {
        fallbackLock.lock()
        let cached = lastGoodFrame
        fallbackLock.unlock()
        // Never acknowledge an exact seek with a frame from another time or
        // edit. Cancellation lets AVPlayer retain its displayed image while
        // decoding/recovery continues, without labelling old pixels as new.
        return cached?.frame(sessionID: instruction.renderSessionID,
            revision: instruction.livePreviewState?.snapshot().revision ?? 0,
            time: time, size: instruction.renderSize)
    }

    private func currentGeneration() -> UInt {
        stateLock.lock()
        defer { stateLock.unlock() }
        return requestGeneration
    }

    private func isCurrent(_ generation: UInt) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return requestGeneration == generation
    }
}
