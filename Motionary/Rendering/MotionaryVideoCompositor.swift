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
    private struct LastGoodFrame {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let data: Data
    }

    private final class RequestFinisher: @unchecked Sendable {
        private let lock = NSLock()
        private var didFinish = false

        @discardableResult
        func finish(_ action: () -> Void) -> Bool {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return false
            }
            didFinish = true
            lock.unlock()
            action()
            return true
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didFinish
        }
    }

    private final class PixelBufferBox: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer

        init(_ pixelBuffer: CVPixelBuffer) {
            self.pixelBuffer = pixelBuffer
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
                    let destinationBox = PixelBufferBox(destination)
                    let finisher = RequestFinisher()
                    let timeoutMilliseconds = self.frameTimeoutMilliseconds(for: instruction)
                    self.timeoutQueue.asyncAfter(deadline: .now() + .milliseconds(timeoutMilliseconds)) { [weak self] in
                        guard let self, self.isCurrent(generation) else { return }
                        finisher.finish {
                            self.logFrameTimeoutIfNeeded(
                                instruction: instruction,
                                timeoutMilliseconds: timeoutMilliseconds
                            )
                            self.recordFrameFailure(MetalRenderingError.cancelled, instruction: instruction)
                            self.renderFallbackFrame(
                                into: destinationBox.pixelBuffer,
                                instruction: instruction
                            )
                            self.recoverRendererAfterTimeout()
                            request.finish(withComposedVideoFrame: destinationBox.pixelBuffer)
                        }
                    }
                    let plan = RenderPlanCompiler.compile(instruction)
                    renderer.renderAsync(
                        plan: plan,
                        compositionTime: request.compositionTime,
                        sourceFrame: { trackID in request.sourceFrame(byTrackID: trackID) },
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
                                self.recordSuccessfulFrame(instruction: instruction)
                                self.storeLastGoodFrame(from: destination)
                                request.finish(withComposedVideoFrame: destination)
                            }
                        case .failure(MetalRenderingError.cancelled):
                            finisher.finish {
                                request.finishCancelledRequest()
                            }
                        case .failure(let error):
                            finisher.finish {
                                self.recordFrameFailure(error, instruction: instruction)
                                self.logger.error("Frame rendering failed: \(error.localizedDescription, privacy: .public)")
                                self.renderFallbackFrame(
                                    into: destination,
                                    instruction: instruction
                                )
                                request.finish(withComposedVideoFrame: destination)
                            }
                        }
                    }
                } catch MetalRenderingError.cancelled {
                    request.finishCancelledRequest()
                } catch {
                    self.recordFrameFailure(error, instruction: instruction)
                    self.logger.error("Frame rendering failed: \(error.localizedDescription, privacy: .public)")
                    if let destination = request.renderContext.newPixelBuffer() {
                        self.renderFallbackFrame(
                            into: destination,
                            instruction: instruction
                        )
                        request.finish(withComposedVideoFrame: destination)
                    } else {
                        request.finish(with: error)
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

    private func recordSuccessfulFrame(instruction: MotionaryVideoCompositionInstruction) {
        let shouldNotify: Bool
        stateLock.lock()
        consecutiveRenderFailures = 0
        let now = CFAbsoluteTimeGetCurrent()
        shouldNotify = now - lastSuccessNotificationAt > 0.25
        if shouldNotify {
            lastSuccessNotificationAt = now
        }
        stateLock.unlock()
        if shouldNotify {
            NotificationCenter.default.post(
                name: .motionaryVideoCompositorRenderedFrame,
                object: self,
                userInfo: ["renderSessionID": instruction.renderSessionID]
            )
        }
    }

    private func recordFrameFailure(
        _ error: Error,
        instruction: MotionaryVideoCompositionInstruction
    ) {
        stateLock.lock()
        consecutiveRenderFailures += 1
        stateLock.unlock()
    }

    private func recoverRendererAfterTimeout() {
        clearLastGoodFrame()
        guard case .success(let renderer) = rendererResult else { return }
        renderer.renderContextDidChange()
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
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow > 0 else { return }
        let byteCount = bytesPerRow * height
        let data = Data(bytes: baseAddress, count: byteCount)
        fallbackLock.lock()
        lastGoodFrame = LastGoodFrame(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            data: data
        )
        fallbackLock.unlock()
    }

    private func renderFallbackFrame(
        into pixelBuffer: CVPixelBuffer,
        instruction: MotionaryVideoCompositionInstruction
    ) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        fallbackLock.lock()
        let cachedFrame = lastGoodFrame
        fallbackLock.unlock()

        if let cachedFrame,
            cachedFrame.width == width,
            cachedFrame.height == height,
            cachedFrame.bytesPerRow == bytesPerRow
        {
            cachedFrame.data.withUnsafeBytes { bytes in
                guard let source = bytes.baseAddress else { return }
                memcpy(baseAddress, source, cachedFrame.data.count)
            }
            return
        }

        fill(
            pixelBufferBaseAddress: baseAddress,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            color: instruction.backgroundColor
        )
    }

    private func fill(
        pixelBufferBaseAddress baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        color: RGBAColor
    ) {
        let blue = UInt8((min(max(color.blue, 0), 1) * 255).rounded())
        let green = UInt8((min(max(color.green, 0), 1) * 255).rounded())
        let red = UInt8((min(max(color.red, 0), 1) * 255).rounded())
        let alpha = UInt8((min(max(color.alpha, 0), 1) * 255).rounded())
        for row in 0..<height {
            let rowStart = baseAddress.advanced(by: row * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                let offset = column * 4
                rowStart[offset] = blue
                rowStart[offset + 1] = green
                rowStart[offset + 2] = red
                rowStart[offset + 3] = alpha
            }
        }
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
