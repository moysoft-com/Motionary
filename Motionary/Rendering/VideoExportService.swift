// Configurable final media export and Photos-library persistence.

@preconcurrency import AVFoundation
import Foundation
import Photos

enum ExportVideoCodec: String, CaseIterable, Identifiable {
    case h264
    case hevc

    var id: String { rawValue }
    var title: String { self == .h264 ? "H.264" : "HEVC" }
    var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}

enum ExportContainer: String, CaseIterable, Identifiable {
    case mp4
    case mov

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }
    var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

struct VideoExportSettings: Equatable {
    var width: Int
    var height: Int
    var frameRate: Int32
    var videoBitrate: Int
    var audioBitrate: Int
    var codec: ExportVideoCodec
    var container: ExportContainer

    static func recommended(for project: EditorProject) -> VideoExportSettings {
        let pixelsPerSecond =
            Double(max(project.renderSettings.width, 1))
            * Double(max(project.renderSettings.height, 1))
            * Double(max(project.renderSettings.frameRate, 1))
        let estimatedBitrate = Int(min(max(pixelsPerSecond * 0.075, 4_000_000), 50_000_000))
        return VideoExportSettings(
            width: project.renderSettings.width,
            height: project.renderSettings.height,
            frameRate: project.renderSettings.frameRate,
            videoBitrate: estimatedBitrate,
            audioBitrate: 192_000,
            codec: .h264,
            container: .mp4
        )
    }

    var normalized: VideoExportSettings {
        var copy = self
        copy.width = min(max(copy.width - copy.width % 2, 2), 7680)
        copy.height = min(max(copy.height - copy.height % 2, 2), 7680)
        copy.frameRate = min(max(copy.frameRate, 1), 120)
        copy.videoBitrate = min(max(copy.videoBitrate, 500_000), 120_000_000)
        copy.audioBitrate = min(max(copy.audioBitrate, 64_000), 320_000)
        return copy
    }
}

enum VideoExportError: LocalizedError {
    case emptyProject
    case noVideo
    case readerUnavailable
    case writerUnavailable
    case exportFailed(String)
    case photoLibraryAccessDenied

    var errorDescription: String? {
        switch self {
        case .emptyProject:
            "Add at least one clip before exporting."
        case .noVideo:
            "The Photos library export requires at least one visual clip."
        case .readerUnavailable:
            "Motionary could not create the export reader."
        case .writerUnavailable:
            "Motionary could not create the export writer."
        case .exportFailed(let message):
            message
        case .photoLibraryAccessDenied:
            "Allow Motionary to add videos to your Photos library in Settings."
        }
    }
}

struct VideoExportService {
    private let renderService = CompositionRenderService()

    func export(
        project: EditorProject,
        settings: VideoExportSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let settings = settings.normalized
        var renderProject = project
        renderProject.renderSettings = RenderSettings(
            width: settings.width,
            height: settings.height,
            frameRate: settings.frameRate,
            backgroundColor: project.renderSettings.backgroundColor
        )

        let rendered = try await renderService.makeComposition(for: renderProject)
        guard rendered.duration > 0 else {
            throw VideoExportError.emptyProject
        }
        guard rendered.hasVideo, let videoComposition = rendered.videoComposition else {
            throw VideoExportError.noVideo
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(UUID().uuidString)_motionary_export.\(settings.container.fileExtension)"
            )
        try? FileManager.default.removeItem(at: outputURL)

        let reader = try AVAssetReader(asset: rendered.composition)
        let videoTracks = rendered.composition.tracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                // Keep the compositor's working buffer private and hand the encoder
                // compact video-range YUV instead of another 4-byte BGRA frame.
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            ]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw VideoExportError.readerUnavailable
        }
        reader.add(videoOutput)

        let audioTracks = rendered.composition.tracks(withMediaType: .audio)
        let audioOutput: AVAssetReaderAudioMixOutput? =
            audioTracks.isEmpty
            ? nil
            : AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
        if let audioOutput {
            audioOutput.audioMix = rendered.audioMix
            guard reader.canAdd(audioOutput) else {
                throw VideoExportError.readerUnavailable
            }
            reader.add(audioOutput)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: settings.container.fileType)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.videoBitrate,
            AVVideoExpectedSourceFrameRateKey: settings.frameRate,
            AVVideoMaxKeyFrameIntervalKey: Int(settings.frameRate * 2),
            AVVideoAllowFrameReorderingKey: true
        ]
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: settings.codec.avCodec,
                AVVideoWidthKey: settings.width,
                AVVideoHeightKey: settings.height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ],
                AVVideoCompressionPropertiesKey: compression
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw VideoExportError.writerUnavailable
        }
        writer.add(videoInput)

        let audioInput: AVAssetWriterInput? =
            audioOutput == nil
            ? nil
            : AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: settings.audioBitrate
                ]
            )
        if let audioInput {
            audioInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(audioInput) else {
                throw VideoExportError.writerUnavailable
            }
            writer.add(audioInput)
        }

        try await transcode(
            reader: reader,
            writer: writer,
            videoOutput: videoOutput,
            videoInput: videoInput,
            audioOutput: audioOutput,
            audioInput: audioInput,
            duration: rendered.duration,
            progress: progress
        )
        return outputURL
    }

    private func transcode(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoOutput: AVAssetReaderVideoCompositionOutput,
        videoInput: AVAssetWriterInput,
        audioOutput: AVAssetReaderAudioMixOutput?,
        audioInput: AVAssetWriterInput?,
        duration: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let pipeline = ExportPipelineState(
            reader: reader,
            writer: writer,
            videoOutput: videoOutput,
            videoInput: videoInput,
            audioOutput: audioOutput,
            audioInput: audioInput,
            duration: duration,
            progress: progress
        )
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue(label: "com.motionary.video-export", qos: .userInitiated).async {
                    guard !pipeline.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                guard pipeline.reader.startReading() else {
                    continuation.resume(
                        throwing: VideoExportError.exportFailed(
                            pipeline.reader.error?.localizedDescription ?? "The export reader could not start."
                        ))
                    return
                }
                guard pipeline.writer.startWriting() else {
                    pipeline.reader.cancelReading()
                    continuation.resume(
                        throwing: VideoExportError.exportFailed(
                            pipeline.writer.error?.localizedDescription ?? "The export writer could not start."
                        ))
                    return
                }

                pipeline.writer.startSession(atSourceTime: .zero)
                var videoFinished = false
                var audioFinished = pipeline.audioOutput == nil || pipeline.audioInput == nil
                var failedError: Error?

                while (!videoFinished || !audioFinished) && failedError == nil {
                    if pipeline.isCancelled {
                        failedError = CancellationError()
                        break
                    }
                    var appendedSample = false

                    if !videoFinished, pipeline.videoInput.isReadyForMoreMediaData {
                        if let sample = pipeline.videoOutput.copyNextSampleBuffer() {
                            appendedSample = true
                            if !pipeline.videoInput.append(sample) {
                                failedError =
                                    pipeline.writer.error
                                    ?? VideoExportError.exportFailed("A video frame could not be encoded.")
                            } else {
                                let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                                if seconds.isFinite {
                                    pipeline.progress(
                                        min(max(seconds / max(pipeline.duration, 0.001), 0), 0.995)
                                    )
                                }
                            }
                        } else {
                            videoFinished = true
                            pipeline.videoInput.markAsFinished()
                        }
                    }

                    if !audioFinished,
                        let audioOutput = pipeline.audioOutput,
                        let audioInput = pipeline.audioInput,
                        audioInput.isReadyForMoreMediaData
                    {
                        if let sample = audioOutput.copyNextSampleBuffer() {
                            appendedSample = true
                            if !audioInput.append(sample) {
                                failedError =
                                    pipeline.writer.error
                                    ?? VideoExportError.exportFailed("The audio track could not be encoded.")
                            }
                        } else {
                            audioFinished = true
                            audioInput.markAsFinished()
                        }
                    }

                    if pipeline.reader.status == .failed {
                        failedError =
                            pipeline.reader.error
                            ?? VideoExportError.exportFailed("The export reader failed.")
                    }
                    if pipeline.writer.status == .failed {
                        failedError =
                            pipeline.writer.error
                            ?? VideoExportError.exportFailed("The export writer failed.")
                    }
                    if !appendedSample, failedError == nil {
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                }

                if let failedError {
                    pipeline.reader.cancelReading()
                    pipeline.writer.cancelWriting()
                    continuation.resume(throwing: failedError)
                    return
                }

                pipeline.writer.finishWriting {
                    if pipeline.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if pipeline.writer.status == .completed {
                        pipeline.progress(1)
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: VideoExportError.exportFailed(
                                pipeline.writer.error?.localizedDescription ?? "The export could not be completed."
                            ))
                    }
                }
            }
            }
        } onCancel: {
            pipeline.requestCancellation()
        }
    }
}

private final class ExportPipelineState: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let videoOutput: AVAssetReaderVideoCompositionOutput
    let videoInput: AVAssetWriterInput
    let audioOutput: AVAssetReaderAudioMixOutput?
    let audioInput: AVAssetWriterInput?
    let duration: Double
    let progress: @Sendable (Double) -> Void
    private let cancellationLock = NSLock()
    private var cancellationRequested = false

    var isCancelled: Bool {
        cancellationLock.withLock { cancellationRequested }
    }

    init(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoOutput: AVAssetReaderVideoCompositionOutput,
        videoInput: AVAssetWriterInput,
        audioOutput: AVAssetReaderAudioMixOutput?,
        audioInput: AVAssetWriterInput?,
        duration: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) {
        self.reader = reader
        self.writer = writer
        self.videoOutput = videoOutput
        self.videoInput = videoInput
        self.audioOutput = audioOutput
        self.audioInput = audioInput
        self.duration = duration
        self.progress = progress
    }

    func requestCancellation() {
        cancellationLock.withLock {
            cancellationRequested = true
        }
        reader.cancelReading()
        writer.cancelWriting()
    }
}

enum PhotoLibraryExportService {
    static func saveVideo(at url: URL) async throws {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw VideoExportError.photoLibraryAccessDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
