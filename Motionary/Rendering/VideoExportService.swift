import AVFoundation
import Foundation

enum VideoExportError: LocalizedError {
    case emptyProject
    case exportSessionUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyProject:
            "Add at least one clip before exporting."
        case .exportSessionUnavailable:
            "Motionary could not create an export session."
        case .exportFailed(let message):
            message
        }
    }
}

struct VideoExportService {
    private let renderService = CompositionRenderService()

    func export(project: EditorProject, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let rendered = try await renderService.makeComposition(for: project)
        guard rendered.duration > 0 else {
            throw VideoExportError.emptyProject
        }

        let preset = rendered.hasVideo ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A
        guard let exportSession = AVAssetExportSession(asset: rendered.composition, presetName: preset) else {
            throw VideoExportError.exportSessionUnavailable
        }

        let fileExtension = rendered.hasVideo ? "mov" : "m4a"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)_motionary_export.\(fileExtension)")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = rendered.hasVideo ? .mov : .m4a
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.videoComposition = rendered.videoComposition

        let progressTask = Task {
            while !Task.isCancelled {
                progress(Double(exportSession.progress))
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        await exportSession.export()
        progressTask.cancel()
        progress(1)

        switch exportSession.status {
        case .completed:
            return outputURL
        case .failed:
            throw VideoExportError.exportFailed(exportSession.error?.localizedDescription ?? "Export failed.")
        case .cancelled:
            throw VideoExportError.exportFailed("Export was cancelled.")
        default:
            throw VideoExportError.exportFailed("Export ended with status \(exportSession.status.rawValue).")
        }
    }
}
