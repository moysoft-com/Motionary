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
    private struct LastGoodFrame {
        let pixelBuffer: CVPixelBuffer
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
                            sourceFrame: { request.sourceFrame(byTrackID: $0) },
                            destination: destination,
                            isCancelled: { !self.isCurrent(generation) }
                        )
                        request.finish(withComposedVideoFrame: destination)
                        return
                    }
                    let finisher = RequestFinisher()
                    let timeoutMilliseconds = self.frameTimeoutMilliseconds(for: instruction)
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
                        guard let fallback = request.renderContext.newPixelBuffer() else {
                            request.finish(with: MetalRenderingError.invalidRenderTarget)
                            return
                        }
                        if self.copyLastCompleteFrame(into: fallback) {
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
                                        abs(time - CMTimeGetSeconds(frameTime)) < 0.000_01
                                    else { return false }
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
                                        renderer.renderAsync(
                                            plan: RenderPlanCompiler.compile(instruction),
                                            compositionTime: frameTime,
                                            sourceFrame: { cachedSources[$0] },
                                            destination: destination,
                                            isCancelled: {
                                                liveFinisher.isFinished || !self.isCurrent(cachedGeneration)
                                            }
                                        ) { result in
                                            liveFinisher.finish {
                                                if case .success = result { completion(destination) }
                                                else { completion(nil) }
                                            }
                                        }
                                    }
                                    return true
                                }
                                self.recordSuccessfulFrame(instruction: instruction, time: request.compositionTime, frame: destination)
                                self.storeLastGoodFrame(from: destination)
                                request.finish(withComposedVideoFrame: destination)
                            }
                        case .failure(MetalRenderingError.sourceFrameUnavailable):
                            finisher.finish {
                                if self.copyLastCompleteFrame(into: destination) {
                                    request.finish(withComposedVideoFrame: destination)
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
                                if self.copyLastCompleteFrame(into: destination) {
                                    request.finish(withComposedVideoFrame: destination)
                                } else {
                                    request.finishCancelledRequest()
                                }
                            }
                        }
                    }
                } catch MetalRenderingError.sourceFrameUnavailable {
                    if instruction.qualityProfile == .export {
                        request.finish(with: MetalRenderingError.sourceFrameUnavailable)
                    } else if let destination = request.renderContext.newPixelBuffer(),
                        self.copyLastCompleteFrame(into: destination) {
                        request.finish(withComposedVideoFrame: destination)
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
                    if let destination = request.renderContext.newPixelBuffer(),
                        self.copyLastCompleteFrame(into: destination) {
                        request.finish(withComposedVideoFrame: destination)
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

    private func recordSuccessfulFrame(instruction: MotionaryVideoCompositionInstruction, time: CMTime, frame: CVPixelBuffer) {
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
                           "compositionTime": CMTimeGetSeconds(time),
                           "frame": frame]
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

    private func frameTimeoutMilliseconds(
        for instruction: MotionaryVideoCompositionInstruction
    ) -> Int {
        let activeLayerCost = instruction.clips.reduce(0) { total, clip in
            total
                + 1
                + clip.effectStack.effects.filter(\.isEnabled).count * 2
                + (clip.text == nil ? 0 : 2)
                + (clip.isAdjustmentLayer ? 2 : 0)
        }
        switch instruction.qualityProfile {
        case .interactive:
            return activeLayerCost > 8 ? 1_800 : 1_200
        case .balanced:
            return activeLayerCost > 8 ? 4_000 : 2_500
        case .export:
            return 5_000
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
            "Frame rendering timed out after \(timeoutMilliseconds, privacy: .public)ms; finishing fallback frame. clips=\(instruction.clips.count, privacy: .public) failures=\(failureCount, privacy: .public)"
        )
    }

    private func storeLastGoodFrame(from pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return
        }
        fallbackLock.lock()
        lastGoodFrame = LastGoodFrame(pixelBuffer: pixelBuffer)
        fallbackLock.unlock()
    }

    @discardableResult
    private func copyLastCompleteFrame(into pixelBuffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return false
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        fallbackLock.lock()
        let cachedFrame = lastGoodFrame
        fallbackLock.unlock()

        if let sourceBuffer = cachedFrame?.pixelBuffer,
            CVPixelBufferGetWidth(sourceBuffer) == width,
            CVPixelBufferGetHeight(sourceBuffer) == height
        {
            CVPixelBufferLockBaseAddress(sourceBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(sourceBuffer, .readOnly) }
            if let source = CVPixelBufferGetBaseAddress(sourceBuffer) {
                let sourceStride = CVPixelBufferGetBytesPerRow(sourceBuffer)
                for row in 0..<height {
                    memcpy(baseAddress.advanced(by: row * bytesPerRow),
                           source.advanced(by: row * sourceStride), width * 4)
                }
                return true
            }
        }
        // A loading/error path must never invent a black/background frame.
        // With no valid fallback, cancelling retains the player's old image.
        return false
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
