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
    case exportInProgress
    case readerUnavailable
    case writerUnavailable
    case unsupportedConfiguration(String)
    case exportFailed(String)
    case photoLibraryAccessDenied

    var errorDescription: String? {
        switch self {
        case .emptyProject:
            "Add at least one clip before exporting."
        case .noVideo:
            "The Photos library export requires at least one visual clip."
        case .exportInProgress:
            "Another video export is already running."
        case .readerUnavailable:
            "Motionary could not create the export reader."
        case .writerUnavailable:
            "Motionary could not create the export writer."
        case .unsupportedConfiguration(let message):
            message
        case .exportFailed(let message):
            message
        case .photoLibraryAccessDenied:
            "Allow Motionary to add videos to your Photos library in Settings."
        }
    }
}

struct VideoExportService {
    private static let coordinator = VideoExportCoordinator()
    private let renderService = CompositionRenderService()

    func export(
        project: EditorProject,
        settings: VideoExportSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await Self.coordinator.acquire()
        do {
            let url = try await performExport(
                project: project,
                settings: settings,
                progress: progress
            )
            await Self.coordinator.release()
            return url
        } catch {
            await Self.coordinator.release()
            throw error
        }
    }

    private func performExport(
        project: EditorProject,
        settings: VideoExportSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let settings = settings.normalized
        try Task.checkCancellation()
        let outputRenderSettings = RenderSettings(
            width: settings.width,
            height: settings.height,
            frameRate: settings.frameRate,
            backgroundColor: project.renderSettings.backgroundColor
        )
        try validateRenderingAvailability(for: project)

        let rendered = try await renderService.makeComposition(
            for: project,
            renderSettings: outputRenderSettings
        )
        try Task.checkCancellation()
        guard rendered.duration > 0 else {
            throw VideoExportError.emptyProject
        }
        guard rendered.hasVideo, rendered.videoComposition != nil else {
            throw VideoExportError.noVideo
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(UUID().uuidString)_motionary_export.\(settings.container.fileExtension)"
            )
        try? FileManager.default.removeItem(at: outputURL)

        do {
            try await writeExport(
                rendered: rendered,
                settings: settings,
                outputURL: outputURL,
                progress: progress
            )
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    func validateRenderingAvailability(for project: EditorProject) throws {
        try MetalRenderResources.validateAvailability()
        for track in project.tracks where !track.isMuted
            && (track.kind == .visual || track.kind == .shape || track.kind == .text)
        {
            for item in track.items {
                let effectStack: EffectStack
                switch item {
                case .media(let mediaItem)
                    where mediaItem.mediaType != .audio && mediaItem.sourceRange.duration > 0:
                    effectStack = mediaItem.visuals.effectStack
                case .shape(let shapeItem) where shapeItem.sourceRange.duration > 0:
                    effectStack = shapeItem.visuals.effectStack
                case .text(let textItem) where textItem.duration > 0:
                    effectStack = textItem.visuals.effectStack
                case .adjustment(let adjustmentItem) where adjustmentItem.duration > 0:
                    effectStack = adjustmentItem.visuals.effectStack
                case .media, .shape, .text, .caption, .adjustment, .compound:
                    continue
                }
                try EffectRenderRegistry.shared.validate(effectStack)
            }
        }
    }

    private func writeExport(
        rendered: RenderedComposition,
        settings: VideoExportSettings,
        outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let videoComposition = rendered.videoComposition else {
            throw VideoExportError.noVideo
        }

        let reader = try AVAssetReader(asset: rendered.composition)
        let videoTracks = rendered.composition.tracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw VideoExportError.noVideo }
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                // Match the custom compositor's render target. Requesting YUV here
                // can bypass still/generated pixels and pass through the clock track.
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA)
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
                    AVSampleRateKey: 48_000,
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

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: settings.container.fileType)
        } catch {
            throw VideoExportError.unsupportedConfiguration(
                "The selected \(settings.container.title) container is unavailable: \(error.localizedDescription)"
            )
        }
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.videoBitrate,
            AVVideoExpectedSourceFrameRateKey: settings.frameRate,
            AVVideoMaxKeyFrameIntervalKey: Int(settings.frameRate * 2),
            AVVideoAllowFrameReorderingKey: true
        ]
        let videoSettings: [String: Any] = [
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
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw VideoExportError.unsupportedConfiguration(
                "\(settings.codec.title) at \(settings.width)×\(settings.height) and \(settings.frameRate) fps is not supported in \(settings.container.title)."
            )
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw VideoExportError.writerUnavailable
        }
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: settings.audioBitrate
        ]
        if audioOutput != nil,
            !writer.canApply(outputSettings: audioSettings, forMediaType: .audio)
        {
            throw VideoExportError.unsupportedConfiguration(
                "48 kHz stereo AAC audio is not supported in \(settings.container.title)."
            )
        }
        let audioInput: AVAssetWriterInput? =
            audioOutput == nil
            ? nil
            : AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
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
        let queue = DispatchQueue(label: "com.motionary.video-export", qos: .userInitiated)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pipeline.install(continuation)
                queue.async {
                    Self.startTranscode(pipeline, on: queue)
                }
            }
        } onCancel: {
            pipeline.requestCancellation()
        }
    }

    private static func startTranscode(
        _ pipeline: ExportPipelineState,
        on queue: DispatchQueue
    ) {
        switch pipeline.startReadingAndWriting() {
        case .success(true):
            break
        case .success(false):
            return
        case .failure(let error):
            pipeline.fail(error)
            return
        }

        guard pipeline.canContinue else { return }
        pipeline.videoInput.requestMediaDataWhenReady(on: queue) {
            drainVideo(pipeline)
        }
        if let audioInput = pipeline.audioInput {
            audioInput.requestMediaDataWhenReady(on: queue) {
                drainAudio(pipeline)
            }
        }
    }

    private static func drainVideo(_ pipeline: ExportPipelineState) {
        guard pipeline.canContinue else { return }
        while pipeline.videoInput.isReadyForMoreMediaData, pipeline.canContinue {
            if let error = pipelineError(pipeline) {
                pipeline.fail(error)
                return
            }
            guard let sample = pipeline.videoOutput.copyNextSampleBuffer() else {
                if let error = pipelineError(pipeline) {
                    pipeline.fail(error)
                } else {
                    pipeline.videoInput.markAsFinished()
                    finishIfReady(pipeline, videoFinished: true)
                }
                return
            }
            guard pipeline.videoInput.append(sample) else {
                pipeline.fail(
                    pipeline.writer.error
                        ?? VideoExportError.exportFailed("A video frame could not be encoded.")
                )
                return
            }

            let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            if seconds.isFinite {
                pipeline.progress(
                    min(max(seconds / max(pipeline.duration, 0.001), 0), 0.995)
                )
            }
        }
    }

    private static func drainAudio(_ pipeline: ExportPipelineState) {
        guard pipeline.canContinue,
            let audioOutput = pipeline.audioOutput,
            let audioInput = pipeline.audioInput
        else { return }

        while audioInput.isReadyForMoreMediaData, pipeline.canContinue {
            if let error = pipelineError(pipeline) {
                pipeline.fail(error)
                return
            }
            guard let sample = audioOutput.copyNextSampleBuffer() else {
                if let error = pipelineError(pipeline) {
                    pipeline.fail(error)
                } else {
                    audioInput.markAsFinished()
                    finishIfReady(pipeline, audioFinished: true)
                }
                return
            }
            guard audioInput.append(sample) else {
                pipeline.fail(
                    pipeline.writer.error
                        ?? VideoExportError.exportFailed("The audio track could not be encoded.")
                )
                return
            }
        }
    }

    private static func pipelineError(_ pipeline: ExportPipelineState) -> Error? {
        if pipeline.reader.status == .failed {
            return pipeline.reader.error
                ?? VideoExportError.exportFailed("The export reader failed.")
        }
        if pipeline.writer.status == .failed {
            return pipeline.writer.error
                ?? VideoExportError.exportFailed("The export writer failed.")
        }
        if pipeline.reader.status == .cancelled || pipeline.writer.status == .cancelled {
            return CancellationError()
        }
        return nil
    }

    private static func finishIfReady(
        _ pipeline: ExportPipelineState,
        videoFinished: Bool = false,
        audioFinished: Bool = false
    ) {
        guard pipeline.markFinished(video: videoFinished, audio: audioFinished) else { return }
        pipeline.writer.finishWriting {
            if pipeline.isCancelled {
                pipeline.complete(.failure(CancellationError()))
            } else if pipeline.writer.status == .completed {
                pipeline.progress(1)
                pipeline.complete(.success(()))
            } else {
                pipeline.complete(
                    .failure(
                        VideoExportError.exportFailed(
                            pipeline.writer.error?.localizedDescription
                                ?? "The export could not be completed."
                        )
                    )
                )
            }
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
    private let stateLock = NSLock()
    private var cancellationRequested = false
    private var readerWasStarted = false
    private var writerWasStarted = false
    private var videoFinished = false
    private var audioFinished: Bool
    private var writerIsFinishing = false
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    private let cancellationQueue = DispatchQueue(
        label: "com.motionary.video-export.cancellation",
        qos: .userInitiated
    )

    var isCancelled: Bool {
        stateLock.withLock { cancellationRequested }
    }

    var canContinue: Bool {
        stateLock.withLock { result == nil && !cancellationRequested }
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
        self.audioFinished = audioOutput == nil || audioInput == nil
    }

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        let completedResult: Result<Void, Error>? = stateLock.withLock {
            if let result {
                return result
            }
            self.continuation = continuation
            return nil
        }
        if let completedResult {
            continuation.resume(with: completedResult)
        }
    }

    func markFinished(video: Bool = false, audio: Bool = false) -> Bool {
        stateLock.withLock {
            guard result == nil, !writerIsFinishing else { return false }
            videoFinished = videoFinished || video
            audioFinished = audioFinished || audio
            guard videoFinished, audioFinished else { return false }
            writerIsFinishing = true
            return true
        }
    }

    func startReadingAndWriting() -> Result<Bool, Error> {
        stateLock.withLock {
            guard result == nil, !cancellationRequested else { return .success(false) }
            guard reader.startReading() else {
                return .failure(
                    VideoExportError.exportFailed(
                        reader.error?.localizedDescription
                            ?? "The export reader could not start."
                    )
                )
            }
            readerWasStarted = true
            guard writer.startWriting() else {
                return .failure(
                    VideoExportError.exportFailed(
                        writer.error?.localizedDescription
                            ?? "The export writer could not start."
                    )
                )
            }
            writerWasStarted = true
            writer.startSession(atSourceTime: .zero)
            return .success(true)
        }
    }

    func requestCancellation() {
        let shouldCancel = stateLock.withLock {
            guard result == nil, !cancellationRequested else { return false }
            cancellationRequested = true
            return true
        }
        guard shouldCancel else { return }

        reader.cancelReading()
        writer.cancelWriting()
        awaitCancellationTermination(deadline: .now() + .milliseconds(900))
    }

    func fail(_ error: Error) {
        let transition = prepareCompletion(.failure(error))
        guard transition.didComplete else { return }
        reader.cancelReading()
        writer.cancelWriting()
        transition.continuation?.resume(with: .failure(error))
    }

    func complete(_ result: Result<Void, Error>) {
        let transition = prepareCompletion(result)
        guard transition.didComplete else { return }
        transition.continuation?.resume(with: result)
    }

    private func awaitCancellationTermination(deadline: DispatchTime) {
        let started = stateLock.withLock { (readerWasStarted, writerWasStarted) }
        if Self.isTerminal(reader.status, wasStarted: started.0),
            Self.isTerminal(writer.status, wasStarted: started.1)
        {
            completeCancellation()
            return
        }

        if DispatchTime.now() >= deadline {
            // AVFoundation normally transitions synchronously after cancellation.
            // Reassert cancellation at the bounded deadline, but never release the
            // caller (which may delete the partial file) while either endpoint is
            // still actively reading or writing.
            reader.cancelReading()
            writer.cancelWriting()
        }

        cancellationQueue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in
            awaitCancellationTermination(deadline: deadline)
        }
    }

    private func completeCancellation() {
        let transition = prepareCompletion(
            .failure(CancellationError()),
            allowAfterCancellation: true
        )
        guard transition.didComplete else { return }
        transition.continuation?.resume(with: .failure(CancellationError()))
    }

    private static func isTerminal(
        _ status: AVAssetReader.Status,
        wasStarted: Bool
    ) -> Bool {
        switch status {
        case .completed, .failed, .cancelled:
            true
        case .unknown:
            !wasStarted
        case .reading:
            false
        @unknown default:
            false
        }
    }

    private static func isTerminal(
        _ status: AVAssetWriter.Status,
        wasStarted: Bool
    ) -> Bool {
        switch status {
        case .completed, .failed, .cancelled:
            true
        case .unknown:
            !wasStarted
        case .writing:
            false
        @unknown default:
            false
        }
    }

    private func prepareCompletion(
        _ completedResult: Result<Void, Error>,
        allowAfterCancellation: Bool = false
    ) -> (didComplete: Bool, continuation: CheckedContinuation<Void, Error>?) {
        stateLock.withLock {
            guard result == nil,
                allowAfterCancellation || !cancellationRequested
            else { return (false, nil) }
            result = completedResult
            let continuation = continuation
            self.continuation = nil
            return (true, continuation)
        }
    }
}

private actor VideoExportCoordinator {
    private var isExporting = false

    func acquire() throws {
        guard !isExporting else { throw VideoExportError.exportInProgress }
        isExporting = true
    }

    func release() {
        isExporting = false
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
