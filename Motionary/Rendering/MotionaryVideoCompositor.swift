// Thin AVFoundation adapter for Rendering Engine v2.

@preconcurrency import AVFoundation
import Foundation
import os

final class MotionaryVideoCompositor: NSObject, AVVideoCompositing {
    private let renderQueue = DispatchQueue(
        label: "com.moysoft.motionary.video-compositor",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let stateLock = NSLock()
    private var requestGeneration: UInt = 0
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
        if case .success(let renderer) = rendererResult {
            renderer.purgeCaches()
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

        let generation = generationForNewRequest(quality: instruction.qualityProfile)
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
                    let plan = RenderPlanCompiler.compile(instruction)
                    renderer.renderAsync(
                        plan: plan,
                        compositionTime: request.compositionTime,
                        sourceFrame: { trackID in request.sourceFrame(byTrackID: trackID) },
                        destination: destination,
                        isCancelled: { !self.isCurrent(generation) }
                    ) { [weak self] result in
                        guard let self else {
                            request.finishCancelledRequest()
                            return
                        }
                        guard self.isCurrent(generation) else {
                            request.finishCancelledRequest()
                            return
                        }
                        switch result {
                        case .success:
                            request.finish(withComposedVideoFrame: destination)
                        case .failure(MetalRenderingError.cancelled):
                            request.finishCancelledRequest()
                        case .failure(let error):
                            self.logger.error("Frame rendering failed: \(error.localizedDescription, privacy: .public)")
                            request.finish(with: error)
                        }
                    }
                } catch MetalRenderingError.cancelled {
                    request.finishCancelledRequest()
                } catch {
                    self.logger.error("Frame rendering failed: \(error.localizedDescription, privacy: .public)")
                    request.finish(with: error)
                }
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        stateLock.lock()
        requestGeneration &+= 1
        stateLock.unlock()
    }

    private func generationForNewRequest(quality: RenderQualityProfile) -> UInt {
        stateLock.lock()
        if quality == .interactive {
            requestGeneration &+= 1
        }
        let generation = requestGeneration
        stateLock.unlock()
        return generation
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
