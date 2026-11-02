// Rebuild the opaque legacy alternate icon from its existing approved preview.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceFolder = root.appendingPathComponent("Motionary/Assets.xcassets/MotionaryWBPreview.imageset")
guard let source = try FileManager.default.contentsOfDirectory(at: sourceFolder, includingPropertiesForKeys: nil)
    .first(where: { $0.pathExtension == "png" }) else { throw CocoaError(.fileReadNoSuchFile) }
let output = root.appendingPathComponent("Motionary/Resources/AlternateIcons")
guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(input, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
guard let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.coderInvalidValue) }
let bounds = CGRect(x: 0, y: 0, width: 1024, height: 1024)
context.setFillColor(CGColor(red: 0.33725, green: 0.52941, blue: 0.85882, alpha: 1))
context.fill(bounds)
context.draw(image, in: bounds)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
guard let raster = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
let slots = [
    ("MotionaryWBFallback60x60@2x.png", 120), ("MotionaryWBFallback60x60@3x.png", 180),
    ("MotionaryWBFallback76x76@2x~ipad.png", 152), ("MotionaryWBFallback83.5x83.5@2x~ipad.png", 167)
]
for (file, pixels) in slots {
    guard let scaled = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
        let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(file) as CFURL,
            UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
    scaled.interpolationQuality = .high
    scaled.draw(raster, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let image = scaled.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
