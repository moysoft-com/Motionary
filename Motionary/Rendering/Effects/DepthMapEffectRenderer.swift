import CoreImage
import CoreML
import CoreVideo
import Foundation

/// Estimates relative depth on-device. The model is loaded only when this effect is used.
final class DepthModel: @unchecked Sendable {
    static let shared = DepthModel()
    private let lock = NSLock()
    private var model: MLModel?
    private var predictions = 0

    var predictionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return predictions
    }

    func predict(_ input: CVPixelBuffer) throws -> CVPixelBuffer {
        lock.lock()
        defer { lock.unlock() }
        if model == nil {
            guard let url = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") else {
                throw MetalRenderingError.unavailableEffect("Depth Map model")
            }
            let configuration = MLModelConfiguration()
            #if targetEnvironment(simulator)
                configuration.computeUnits = .cpuOnly
            #else
                configuration.computeUnits = .all
            #endif
            model = try MLModel(contentsOf: url, configuration: configuration)
        }
        let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
        guard let depth = try model?.prediction(from: features).featureValue(for: "depth")?.imageBufferValue else {
            throw MetalRenderingError.unavailableEffect("Depth Map output")
        }
        predictions += 1
        return depth
    }
}

struct DepthMapEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID = .depthMap

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext,
                resources: MetalFrameResources) throws -> EffectRenderResult {
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
            throw MetalRenderingError.invalidRenderTarget
        }
        let map: CIImage
        if let analysis = context.depthAnalyses[effect.id] {
            if let track = analysis.track {
                map = try DepthBakeStore.shared.image(track: track, time: context.clipTime)
            } else {
                map = try DepthBakeStore.shared.still(
                    image, effectID: effect.id, directory: analysis.directory,
                    sourceFile: context.usesUnmaskedStillDepth ? analysis.stillFile : nil
                )
            }
        } else if let source = context.temporalSource {
            map = try DepthBakeStore.shared.image(source: source, effect: effect, time: context.clipTime)
        } else {
            map = try DepthBakeStore.shared.still(image, effectID: effect.id)
        }
        var depth = map.clampedToExtent().transformed(by: CGAffineTransform(scaleX: extent.width / map.extent.width,
                                                         y: extent.height / map.extent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        let contrast = scalar(.contrast, in: effect, at: context.clipTime)
        depth = depth.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.5 + contrast])
        if case .option("Near is black")? = EffectRegistry.shared.resolvedValue(for: "depthDirection", in: effect, at: context.clipTime) {
            depth = depth.applyingFilter("CIColorInvert")
        }
        let brightness = scalar("depthBrightness", in: effect, at: context.clipTime)
        depth = depth.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: brightness])
        if case .option(let style)? = EffectRegistry.shared.resolvedValue(for: "depthStyle", in: effect, at: context.clipTime) {
            switch style {
            case "Bands":
                depth = depth.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 2 + scalar("depthBands", in: effect, at: context.clipTime) * 14])
            case "Edges":
                depth = depth.clampedToExtent().applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 3]).cropped(to: extent)
            case "Thermal":
                depth = depth.applyingFilter("CIFalseColor", parameters: ["inputColor0": CIColor(red: 0.05, green: 0.05, blue: 0.4), "inputColor1": CIColor(red: 1, green: 0.25, blue: 0.02)])
            default: break
            }
        }
        let clear = CIImage(color: .clear).cropped(to: extent)
        let output = depth.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: image,
        ])
        return EffectRenderResult(image: output.cropped(to: extent))
    }
}
