import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A self-contained playback file. The versioned header is followed by the rendered movie bytes.
enum MotionaryVideoArchive {
    static let fileExtension = "motionaryvideo"
    typealias ArchiveError = MotionaryVideoContainer.ArchiveError

    private struct Header: Codable {
        let movieExtension: String
        let movieBytes: UInt64
        let haptics: HapticTrack
        let posterJPEG: Data?
    }

    struct Movie: Identifiable, Sendable {
        let url: URL
        let title: String
        let haptics: HapticTrack

        var id: URL { url }

        func removeTemporaryFiles() {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    static func makePosterJPEG(from asset: AVAsset) async throws -> Data? {
        let frame = try await MotionaryVideoContainer.posterFrame(from: asset, maximumPixelSize: 512)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        CGImageDestinationAddImage(destination, frame, options)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func write(movie: URL, title: String, haptics: HapticTrack, posterJPEG: Data? = nil) throws -> URL {
        let fileManager = FileManager.default
        let movieExtension = movie.pathExtension.lowercased()
        guard ["mp4", "mov"].contains(movieExtension),
            let size = try movie.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0
        else { throw ArchiveError.invalid }
        let encoder = JSONEncoder()
        var header = try encoder.encode(Header(
            movieExtension: movieExtension, movieBytes: UInt64(size), haptics: haptics, posterJPEG: posterJPEG
        ))
        let maximumHeaderBytes = MotionaryVideoContainer.maximumHeaderBytes
        if header.count > maximumHeaderBytes, posterJPEG != nil {
            header = try encoder.encode(Header(
                movieExtension: movieExtension, movieBytes: UInt64(size), haptics: haptics, posterJPEG: nil
            ))
        }
        guard header.count <= maximumHeaderBytes else { throw ArchiveError.unsupported }

        let folder = try MotionaryVideoContainer.makeTemporaryDirectory()
        let safeTitle = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = folder.appendingPathComponent(safeTitle.isEmpty ? "Motionary Video" : String(safeTitle.prefix(60)))
            .appendingPathExtension(fileExtension)
        do {
            let movieFile = try FileHandle(forReadingFrom: movie)
            defer { try? movieFile.close() }
            try Data().write(to: url)
            let archive = try FileHandle(forWritingTo: url)
            defer { try? archive.close() }
            try archive.write(contentsOf: MotionaryVideoContainer.signature)
            var length = UInt32(header.count).bigEndian
            try archive.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
            try archive.write(contentsOf: header)
            try MotionaryVideoContainer.copy(from: movieFile, to: archive, bytes: UInt64(size))
            try archive.close()
            return url
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    static func open(_ url: URL) async throws -> Movie {
        let accessible = url.startAccessingSecurityScopedResource()
        defer { if accessible { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try MotionaryVideoContainer.readHeader(Header.self, from: file)
        guard validate(header.haptics) else { throw ArchiveError.invalid }
        try MotionaryVideoContainer.validateMovie(in: file, extension: header.movieExtension, bytes: header.movieBytes)

        let movie = try MotionaryVideoContainer.extractMovie(
            from: file, extension: header.movieExtension, bytes: header.movieBytes
        )
        do {
            let asset = AVURLAsset(url: movie)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, try await asset.load(.isPlayable),
                try await !asset.loadTracks(withMediaType: .video).isEmpty
            else { throw ArchiveError.invalid }
            return Movie(
                url: movie, title: url.deletingPathExtension().lastPathComponent,
                haptics: HapticTrack(events: header.haptics.events.filter {
                    $0.time < duration && $0.end <= duration + 0.1
                })
            )
        } catch {
            try? FileManager.default.removeItem(at: movie.deletingLastPathComponent())
            throw error
        }
    }

    private static func validate(_ track: HapticTrack) -> Bool {
        var previous = 0.0
        for event in track.events {
            guard event.time.isFinite, event.time >= previous, event.end.isFinite,
                (0...30.000_001).contains(event.duration), !event.samples.isEmpty,
                event.samples.first?.time == 0
            else { return false }
            previous = event.time
            var last = -1.0
            for sample in event.samples {
                guard sample.time > last, sample.time <= event.duration + 0.000_001,
                    (0...1).contains(sample.intensity), (0...1).contains(sample.sharpness)
                else { return false }
                last = sample.time
            }
        }
        return true
    }
}
