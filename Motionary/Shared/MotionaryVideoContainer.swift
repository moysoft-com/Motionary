import AVFoundation
import Foundation

/// The file framing is shared by playback and the Quick Look extension.
enum MotionaryVideoContainer {
    static let signature = Data("MOTIONARYVIDEO1\n".utf8)
    static let maximumHeaderBytes = 16 * 1024 * 1024

    enum ArchiveError: LocalizedError {
        case invalid, unsupported

        var errorDescription: String? {
            switch self {
            case .invalid: "This Motionary Video is missing data or is damaged."
            case .unsupported: "This Motionary Video format is unsupported."
            }
        }
    }

    static func readHeader<Header: Decodable>(_ type: Header.Type, from file: FileHandle) throws -> Header {
        guard try read(signature.count, from: file) == signature else { throw ArchiveError.unsupported }
        let length = try read(4, from: file).reduce(0) { $0 * 256 + Int($1) }
        guard length > 0, length <= maximumHeaderBytes else { throw ArchiveError.invalid }
        do {
            return try JSONDecoder().decode(type, from: read(length, from: file))
        } catch {
            throw ArchiveError.invalid
        }
    }

    static func validateMovie(in file: FileHandle, extension movieExtension: String, bytes: UInt64) throws {
        let offset = try file.offset()
        let total = try file.seekToEnd()
        guard ["mp4", "mov"].contains(movieExtension), bytes > 0, total >= offset, total - offset == bytes
        else { throw ArchiveError.invalid }
        try file.seek(toOffset: offset)
    }

    static func extractMovie(from file: FileHandle, extension movieExtension: String, bytes: UInt64) throws -> URL {
        let directory = try makeTemporaryDirectory()
        let movie = directory.appendingPathComponent("Video").appendingPathExtension(movieExtension)
        do {
            try Data().write(to: movie)
            let output = try FileHandle(forWritingTo: movie)
            defer { try? output.close() }
            try copy(from: file, to: output, bytes: bytes)
            try output.close()
            return movie
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func posterFrame(from asset: AVAsset, maximumPixelSize: CGFloat) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        return try await generator.image(at: .zero).image
    }

    static func makeTemporaryDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func copy(from input: FileHandle, to output: FileHandle, bytes: UInt64) throws {
        var remaining = bytes
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try read(Int(min(remaining, 1024 * 1024)), from: input)
            try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
    }

    private static func read(_ count: Int, from file: FileHandle) throws -> Data {
        guard let data = try file.read(upToCount: count), data.count == count else { throw ArchiveError.invalid }
        return data
    }
}
