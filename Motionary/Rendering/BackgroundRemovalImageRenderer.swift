// Shared source-space cutout pipeline for interactive preview and export.
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

struct BackgroundRemovalImageRenderer {
    private static let cubeCache = NSCache<NSString, NSData>()
    private static let brushCache = NSCache<NSString, CIImage>()

    static func apply(
        _ settings: BackgroundRemovalSettings, matte: CIImage?,
        to source: CIImage, renderScale: CGFloat = 1
    ) -> CIImage {
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return source }
        var image = source
        var mask: CIImage
        switch settings.mode {
        case .automatic:
            guard let matte, matte.extent.width > 0, matte.extent.height > 0 else { return CIImage.empty().cropped(to: extent) }
            mask = matte.transformed(by: CGAffineTransform(translationX: -matte.extent.minX, y: -matte.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: extent.width / matte.extent.width, y: extent.height / matte.extent.height))
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        case .chromaKey:
            let opaqueSource = source.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            let keyed = opaqueSource.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
                "inputCubeDimension": 32, "inputCubeData": cube(for: settings),
            ])
            // Keep the source alpha intact; use the keyed alpha only as the mask.
            mask = keyed
            if settings.spillSuppression > 0, !settings.isInverted {
                image = source.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                    "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
                    "inputCubeDimension": 32, "inputCubeData": cube(for: settings, spillOnly: true),
                ])
            }
        case .custom:
            mask = brushMask(settings.strokes, extent: extent)
        }
        // Work in mask luminance so both opaque PNG and alpha video mattes
        // receive identical morphology, feathering and inversion.
        mask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).cropped(to: extent)
        let edge = abs(settings.edgeRefinement) * 12 * Double(renderScale)
        if edge > 0.05 {
            mask = mask.clampedToExtent().applyingFilter(
                settings.edgeRefinement > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum",
                parameters: [kCIInputRadiusKey: edge]
            ).cropped(to: extent)
        }
        if settings.feather > 0 {
            mask = mask.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: settings.feather * 24 * Double(renderScale),
            ]).cropped(to: extent)
        }
        if settings.isInverted { mask = mask.applyingFilter("CIColorInvert") }
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: extent),
            kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)
    }

    /// Chroma-plane distance tolerates brightness differences in a lit screen.
    /// Neutral key colors use RGB distance so white and black stay distinct.
    static func keyAlpha(red: Double, green: Double, blue: Double, settings: BackgroundRemovalSettings) -> Double {
        let key = settings.keyColor
        let saturation = max(key.red, key.green, key.blue) - min(key.red, key.green, key.blue)
        let distance: Double
        if saturation < 0.1 {
            distance = sqrt(pow(red - key.red, 2) + pow(green - key.green, 2) + pow(blue - key.blue, 2)) / sqrt(3)
        } else {
            let y = 0.299 * red + 0.587 * green + 0.114 * blue
            let ky = 0.299 * key.red + 0.587 * key.green + 0.114 * key.blue
            distance = hypot((blue - y) - (key.blue - ky), (red - y) - (key.red - ky)) / 2
        }
        let lower = settings.tolerance * 0.6
        let width = max(settings.softness * 0.5, 0.001)
        let t = min(max((distance - lower) / width, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func cube(for settings: BackgroundRemovalSettings, spillOnly: Bool = false) -> Data {
        let key = "\(settings.keyColor)-\(settings.tolerance)-\(settings.softness)-\(settings.spillSuppression)-\(spillOnly)" as NSString
        if let cached = cubeCache.object(forKey: key) { return cached as Data }
        let dimension = 32
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        let color = settings.keyColor
        let dominant = max(color.red, color.green, color.blue)
        let saturation = dominant - min(color.red, color.green, color.blue)
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    var rgb = [Double(r) / 31, Double(g) / 31, Double(b) / 31]
                    let alpha = keyAlpha(red: rgb[0], green: rgb[1], blue: rgb[2], settings: settings)
                    if spillOnly, saturation > 0.1 {
                        let index = color.green == dominant ? 1 : (color.blue == dominant ? 2 : 0)
                        let others = rgb.enumerated().filter { $0.offset != index }.map(\.element)
                        let neutral = others.max() ?? 0
                        let amount = settings.spillSuppression * (1 - alpha * 0.7)
                        rgb[index] -= max(rgb[index] - neutral, 0) * amount
                    }
                    let outputAlpha = spillOnly ? 1 : alpha
                    values.append(contentsOf: rgb.map { Float($0 * outputAlpha) })
                    values.append(Float(outputAlpha))
                }
            }
        }
        let data = values.withUnsafeBytes { Data($0) }
        cubeCache.countLimit = 24
        cubeCache.setObject(data as NSData, forKey: key)
        return data
    }

    private static func brushMask(_ strokes: [BackgroundBrushStroke], extent: CGRect) -> CIImage {
        var hasher = Hasher()
        hasher.combine(strokes)
        let key = "\(extent)-\(hasher.finalize())" as NSString
        if let cached = brushCache.object(forKey: key) { return cached }
        let scale = min(1, 2048 / max(extent.width, extent.height))
        let size = CGSize(width: max(1, (extent.width * scale).rounded()), height: max(1, (extent.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let raster = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for stroke in strokes {
                guard let first = stroke.points.first else { continue }
                let diameter = max(1, stroke.diameter * min(size.width, size.height))
                context.setStrokeColor((stroke.restores ? UIColor.white : UIColor.black).cgColor)
                context.setFillColor((stroke.restores ? UIColor.white : UIColor.black).cgColor)
                context.setLineWidth(diameter)
                let start = CGPoint(x: first.x * size.width, y: first.y * size.height)
                context.fillEllipse(in: CGRect(x: start.x - diameter / 2, y: start.y - diameter / 2, width: diameter, height: diameter))
                context.beginPath()
                context.move(to: start)
                for point in stroke.points.dropFirst() {
                    context.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                }
                context.strokePath()
            }
        }
        guard let cgImage = raster.cgImage else { return CIImage(color: .white).cropped(to: extent) }
        let mask = CIImage(cgImage: cgImage).applyingFilter("CIMaskToAlpha")
            .transformed(by: CGAffineTransform(scaleX: extent.width / size.width, y: extent.height / size.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        brushCache.totalCostLimit = 32 * 1024 * 1024
        brushCache.setObject(mask, forKey: key, cost: Int(size.width * size.height) * 4)
        return mask
    }
}
