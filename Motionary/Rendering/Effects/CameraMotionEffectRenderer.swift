import CoreImage
import Foundation
import simd

/// Samples depend on authored time and the stored seed, never render order or
/// preview frame rate. Both motions use continuous, seeded random curves.
enum CameraMotionSampling {
    static func cropScale(aspect: Double, horizontal: Double, vertical: Double, rotation: Double) -> Double {
        let angle = min(abs(rotation), .pi / 2)
        func maximum(_ a: Double, _ b: Double) -> Double {
            let peakAngle = min(angle, atan2(b, a))
            return a * cos(peakAngle) + b * sin(peakAngle)
        }
        let width = 1 + 2 * abs(horizontal)
        let height = 1 + 2 * abs(vertical)
        return max(maximum(width, height / aspect), maximum(height, width * aspect))
    }

    static func noise(at time: Double, seed: UInt64, channel: UInt64, smooth: Bool) -> Double {
        let time = min(max(time.isFinite ? time : 0, 0), 1e12)
        func sample(_ index: UInt64) -> Double {
            var value = seed &+ index &* 0x9e3779b97f4a7c15 &+ channel &* 0x632be59bd9b4e019
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            value ^= value >> 31
            return Double(value >> 11) / Double(UInt64(1) << 53) * 2 - 1
        }
        // Cubic B-splines blend independent random control points with continuous
        // velocity and acceleration, including across segment boundaries. Unlike
        // periodic oscillators, new control points keep arriving as time advances.
        func curve(at position: Double, salt: UInt64) -> Double {
            let index = UInt64(position.rounded(.down))
            let t = position - Double(index)
            let t2 = t * t
            let t3 = t2 * t
            let inverse = 1 - t
            return (sample((index &- 1) &+ salt) * inverse * inverse * inverse
                + sample(index &+ salt) * (3 * t3 - 6 * t2 + 4)
                + sample((index &+ 1) &+ salt) * (-3 * t3 + 3 * t2 + 3 * t + 1)
                + sample((index &+ 2) &+ salt) * t3) / 6
        }
        let position = time * (smooth ? 1 : 2)
        // Independent broad drift and finer movement avoid a regular beat. The
        // convex blend stays within [-1, 1], preserving the auto-crop envelope.
        return curve(at: position, salt: 0) * 0.75
            + curve(at: position * 2.17 + 0.37, salt: 0xd1b54a32d192ed03) * 0.25
    }

    static func zoom(at time: Double, start: Double, end: Double, duration: Double,
                     mode: String, easing: String) -> Double {
        let progress = max(time, 0) / max(duration, 0.05)
        var t = min(progress, 1)
        if mode == "Static" { return start }
        if mode == "Pulse" { t = (1 - cos(progress * 2 * .pi)) * 0.5 }
        switch easing {
        case "Linear": break
        case "Ease In": t *= t * t
        case "Ease Out": t = 1 - pow(1 - t, 3)
        default: t = t * t * (3 - 2 * t)
        }
        let from = mode == "Out" ? max(start, end) : min(start, end)
        let to = mode == "Out" ? min(start, end) : max(start, end)
        return from + (to - from) * t
    }
}

struct CameraMotionEffectRenderer: EffectRenderModule {
    let moduleID: EffectModuleID

    func render(_ image: CIImage, effect: EffectInstance, context: EffectRenderContext,
                resources: MetalFrameResources) throws -> EffectRenderResult {
        func v(_ id: EffectParameterID) -> Double { scalar(id, in: effect, at: context.clipTime) }
        func option(_ id: EffectParameterID) -> String {
            guard case .option(let value)? = EffectRegistry.shared.resolvedValue(
                for: id, in: effect, at: context.clipTime) else { return "" }
            return value
        }
        var center = SIMD2<Float>(0.5, 0.5)
        if case .point(let point)? = EffectRegistry.shared.resolvedValue(for: .center, in: effect, at: context.clipTime) {
            center = SIMD2(Float(point.x), 1 - Float(point.y))
        }
        let edges = option("edges")
        let edgeMode: EffectEdgeMode = switch edges {
        case "Transparent": .transparent
        case "Repeat Tiles": .repeatTile
        case "Clamp", "Auto Crop": .clamp
        default: .unfold
        }
        if moduleID == .mirror {
            let angle: Double = switch option("axis") {
            case "Vertical": 0
            case "Horizontal": -.pi / 2
            default: -cyclicDegrees(.angle, in: effect, at: context.clipTime) * .pi / 180
            }
            return try MetalEffectSupport.renderSinglePass(image, kind: .mirror,
                parameters: SIMD4(Float(cos(angle)), Float(sin(angle)),
                    option("side") == "Right / Bottom" ? 1 : -1, 0),
                center: center, edgeMode: edgeMode, margin: 0,
                effect: effect, context: context, resources: resources)
        }
        var scale: Double
        var rotation = 0.0
        var x = 0.0
        var y = 0.0
        if moduleID == .zoom {
            scale = CameraMotionSampling.zoom(at: context.clipTime, start: v("startScale"), end: v("endScale"),
                duration: v("duration"), mode: option("mode"), easing: option("easing"))
            x = v("offsetX")
            y = -v("offsetY")
        } else {
            let smooth = moduleID == .cameraWiggle
            let seed = effect.seed &+ UInt64(v("seed").rounded())
            let time = max(context.clipTime, 0) * v(.frequency)
            let envelope = smooth ? 1 : exp(-max(context.clipTime, 0) * v(.decay))
            func noise(_ channel: UInt64) -> Double {
                CameraMotionSampling.noise(at: time, seed: seed, channel: channel, smooth: smooth)
            }
            let shortest = min(image.extent.width, image.extent.height)
            x = noise(0) * v(.amount) * envelope * v("horizontal") * shortest / image.extent.width
            y = noise(1) * v(.amount) * envelope * v("vertical") * shortest / image.extent.height
            rotation = noise(2) * cyclicDegrees(.angle, in: effect, at: context.clipTime) * .pi / 180 * envelope
            scale = v("scale")
            if edges == "Auto Crop" {
                // Fit the entire movement envelope, avoiding per-frame zoom pumping.
                scale = max(scale, CameraMotionSampling.cropScale(
                    aspect: image.extent.width / image.extent.height,
                    horizontal: v(.amount) * v("horizontal") * shortest / image.extent.width,
                    vertical: v(.amount) * v("vertical") * shortest / image.extent.height,
                    rotation: cyclicDegrees(.angle, in: effect, at: context.clipTime) * .pi / 180))
            }
        }
        return try MetalEffectSupport.renderSinglePass(image, kind: .cameraTransform,
            parameters: SIMD4(Float(scale), Float(rotation), Float(x), Float(y)),
            center: center, edgeMode: edgeMode, margin: 0,
            effect: effect, context: context, resources: resources)
    }
}

