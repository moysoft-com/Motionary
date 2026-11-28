import AVFoundation
import CoreImage
import Vision

/// Estimates motion at reduced resolution and warps the full-size source.
/// Both fields are reused when a source pair supplies several output frames.
final class SmoothMotionOpticalFlow {
    private struct Fields {
        let forward: CIImage
        let backward: CIImage
        let size: CGSize
    }

    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private let highQuality: Bool
    private var currentTime: CMTime?
    private var nextTime: CMTime?
    private var fields: Fields?
    private var translation = CGSize.zero

    init(highQuality: Bool) {
        self.highQuality = highQuality
    }

    func interpolate(_ current: CIImage, _ next: CIImage, current currentPTS: CMTime,
        next nextPTS: CMTime, phase: Float) -> CIImage {
        let bounds = current.extent
        guard bounds.size == next.extent.size, bounds.width > 0, bounds.height > 0 else {
            return phase < 0.5 ? current : next
        }
        if currentTime != currentPTS || nextTime != nextPTS {
            currentTime = currentPTS
            nextTime = nextPTS
            // Reuse the result within a source pair, including failed requests.
            fields = Self.warp.flatMap { _ in autoreleasepool { try? measure(current, next) } }
            translation = fields == nil ? estimateTranslation(current, next) : .zero
        }
        guard let kernel = Self.warp, let fields else {
            guard translation != .zero else { return phase < 0.5 ? current : next }
            let progress = CGFloat(phase)
            let first = current.clampedToExtent().transformed(by: CGAffineTransform(
                translationX: translation.width * progress, y: translation.height * progress))
            let second = next.clampedToExtent().transformed(by: CGAffineTransform(
                translationX: -translation.width * (1 - progress), y: -translation.height * (1 - progress)))
            return dissolve(first.cropped(to: bounds), second.cropped(to: bounds), at: phase)
        }
        let scale = CGAffineTransform(scaleX: bounds.width / fields.size.width,
            y: bounds.height / fields.size.height)
        let placement = scale.concatenating(CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
        let forward = fields.forward.transformed(by: placement).clampedToExtent()
        let backward = fields.backward.transformed(by: placement).clampedToExtent()
        let vectorScale = CIVector(x: scale.a, y: -scale.d)
        return kernel.apply(extent: bounds, roiCallback: { index, requested in
            bounds
        }, arguments: [current.clampedToExtent(), next.clampedToExtent(), forward, backward, vectorScale, phase])
            ?? (phase < 0.5 ? current : next)
    }

    private func measure(_ current: CIImage, _ next: CIImage) throws -> Fields {
        let bounds = current.extent
        let scale = min(1, (highQuality ? 640 : 480) / max(bounds.width, bounds.height))
        let width = max(Int((bounds.width * scale).rounded()), 8)
        let height = max(Int((bounds.height * scale).rounded()), 8)
        let a = try analysisBuffer(current, width: width, height: height)
        let b = try analysisBuffer(next, width: width, height: height)
        let forward = try vectors(from: a, to: b)
        let backward = try vectors(from: b, to: a)
        return Fields(forward: forward, backward: backward, size: CGSize(width: width, height: height))
    }

    private func analysisBuffer(_ image: CIImage, width: Int, height: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &result)
            == kCVReturnSuccess, let result
        else { throw SmoothMotionError.processingFailed }
        let bounds = image.extent
        let scaled = image.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .transformed(by: CGAffineTransform(scaleX: Double(width) / bounds.width, y: Double(height) / bounds.height))
        context.render(scaled, to: result, bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: VideoColorSpace.rec709)
        return result
    }

    private func vectors(from source: CVPixelBuffer, to target: CVPixelBuffer) throws -> CIImage {
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: target, options: [:])
        request.computationAccuracy = highQuality ? .high : .medium
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        let handler = VNImageRequestHandler(cvPixelBuffer: source, options: [:])
        try handler.perform([request])
        guard let buffer = request.results?.first?.pixelBuffer,
            CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
        else { throw SmoothMotionError.processingFailed }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SmoothMotionError.processingFailed }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        return CIImage(bitmapData: Data(bytes: base, count: stride * height), bytesPerRow: stride,
            size: CGSize(width: width, height: height), format: .RGf, colorSpace: nil)
    }

    /// Coarse translation also covers systems that cannot run Vision's flow.
    private func estimateTranslation(_ current: CIImage, _ next: CIImage) -> CGSize {
        let side = 64
        let radius = 6
        func luma(_ image: CIImage) -> [UInt8] {
            let bounds = image.extent
            let scaled = image.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                .transformed(by: CGAffineTransform(scaleX: Double(side) / bounds.width, y: Double(side) / bounds.height))
            var bytes = [UInt8](repeating: 0, count: side * side)
            context.render(scaled, toBitmap: &bytes, rowBytes: side, bounds: CGRect(x: 0, y: 0, width: side, height: side),
                format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
            return bytes
        }
        let first = luma(current)
        let second = luma(next)
        func error(x: Int, y: Int) -> Int {
            var difference = 0
            for row in radius..<(side - radius) {
                for column in radius..<(side - radius) {
                    let source = Int(first[row * side + column])
                    let target = Int(second[(row + y) * side + column + x])
                    difference += abs(source - target)
                }
            }
            return difference
        }
        let baseline = error(x: 0, y: 0)
        guard baseline > 0 else { return .zero }
        var best = (x: 0, y: 0, score: baseline)
        for y in -radius...radius {
            for x in -radius...radius where x != 0 || y != 0 {
                let score = error(x: x, y: y) + (abs(x) + abs(y)) * 40
                if score < best.score { best = (x, y, score) }
            }
        }
        guard best.score < baseline * 9 / 10 else { return .zero }
        return CGSize(width: Double(best.x) * current.extent.width / Double(side),
            height: Double(best.y) * current.extent.height / Double(side))
    }

    private func dissolve(_ current: CIImage, _ next: CIImage, at phase: Float) -> CIImage {
        current.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: next, kCIInputTimeKey: phase
        ]).cropped(to: current.extent)
    }

    private static let warp = CIKernel(source: """
        kernel vec4 smoothMotion(sampler first, sampler second, sampler forward, sampler backward,
                                  vec2 scale, float t) {
            vec2 p = destCoord();
            vec2 f = sample(forward, samplerTransform(forward, p)).rg * scale;
            vec2 b = sample(backward, samplerTransform(backward, p)).rg * scale;
            vec2 aPoint = p - f * t;
            vec2 bPoint = p - b * (1.0 - t);
            f = sample(forward, samplerTransform(forward, aPoint)).rg;
            b = sample(backward, samplerTransform(backward, bPoint)).rg;
            aPoint = p - f * scale * t;
            bPoint = p - b * scale * (1.0 - t);
            vec4 a = sample(first, samplerTransform(first, aPoint));
            vec4 c = sample(second, samplerTransform(second, bPoint));
            vec2 reverseF = sample(backward, samplerTransform(backward, aPoint + f * scale)).rg;
            vec2 reverseB = sample(forward, samplerTransform(forward, bPoint + b * scale)).rg;
            float confidenceA = 1.0 - smoothstep(1.5, 4.0 + 0.15 * length(f), length(f + reverseF));
            float confidenceB = 1.0 - smoothstep(1.5, 4.0 + 0.15 * length(b), length(b + reverseB));
            float wa = (1.0 - t) * confidenceA;
            float wb = t * confidenceB;
            if (wa + wb < 0.15) {
                return t < 0.5 ? sample(first, samplerTransform(first, p))
                               : sample(second, samplerTransform(second, p));
            }
            return (a * wa + c * wb) / (wa + wb);
        }
        """)
}
