import AVFoundation
import CoreImage
import Foundation
import Testing

@testable import Motionary

@Suite(.serialized)
struct CameraMotionEffectTests {
    private let bounds = CGRect(x: 0, y: 0, width: 80, height: 40)

    private func pixels(_ image: CIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 80 * 40 * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: 80 * 4, bounds: bounds,
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return bytes
    }

    private var pattern: CIImage {
        CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: bounds))
    }

    @Test func motionIsDeterministicAndWiggleHasSmoothTangents() {
        for smooth in [false, true] {
            let first = CameraMotionSampling.noise(at: 1.25, seed: 123, channel: 0, smooth: smooth)
            _ = CameraMotionSampling.noise(at: 8, seed: 123, channel: 0, smooth: smooth)
            #expect(first == CameraMotionSampling.noise(at: 1.25, seed: 123, channel: 0, smooth: smooth))
            #expect(first != CameraMotionSampling.noise(at: 1.25, seed: 124, channel: 0, smooth: smooth))
            #expect((-1...1).contains(first))
        }
        let atJoin = CameraMotionSampling.noise(at: 1, seed: 42, channel: 1, smooth: true)
        let before = CameraMotionSampling.noise(at: 0.999, seed: 42, channel: 1, smooth: true)
        let after = CameraMotionSampling.noise(at: 1.001, seed: 42, channel: 1, smooth: true)
        let leftVelocity = (atJoin - before) / 0.001
        let rightVelocity = (after - atJoin) / 0.001
        #expect(abs(leftVelocity - rightVelocity) < 0.1)
        for time in 1...20 {
            let velocities: [Double] = (0..<3).map { channel in
                let a = CameraMotionSampling.noise(at: Double(time) - 0.001, seed: 42, channel: UInt64(channel), smooth: true)
                let b = CameraMotionSampling.noise(at: Double(time) + 0.001, seed: 42, channel: UInt64(channel), smooth: true)
                return abs((b - a) / 0.002)
            }
            let velocity = velocities.reduce(0.0) { $0 + $1 }
            #expect(velocity > 0.1, "Wiggle must not come to rest at integer lattice times")
        }
    }

    @Test func zoomDirectionsEndpointsAndPulse() {
        func zoom(_ time: Double, _ mode: String) -> Double {
            CameraMotionSampling.zoom(at: time, start: 0.6, end: 1.4, duration: 2,
                mode: mode, easing: "Smooth")
        }
        #expect(zoom(0, "In") == 0.6)
        #expect(abs(zoom(2, "In") - 1.4) < 0.000001)
        #expect(zoom(10, "In") == zoom(2, "In"))
        #expect(zoom(0, "Out") == 1.4)
        #expect(abs(zoom(2, "Out") - 0.6) < 0.000001)
        #expect(zoom(7, "Static") == 0.6)
        #expect(abs(zoom(1, "Pulse") - 1.4) < 0.000001)
        #expect(abs(zoom(2, "Pulse") - 0.6) < 0.000001)
    }

    @Test func newSpatialEffectsRenderDeterministicallyAndBypass() throws {
        let renderer = try MetalFrameRenderer()
        for id: EffectModuleID in [.shake, .cameraWiggle, .zoom, .mirror] {
            var effect = try #require(EffectRegistry.shared.makeEffect(moduleID: id))
            func render(_ time: Double) throws -> CIImage {
                try renderer.renderEffectsSynchronously(EffectStack(effects: [effect]),
                    to: pattern, at: time, renderScale: 1)
            }
            let first = try render(0.37)
            _ = try render(2)
            #expect(first.extent == bounds)
            #expect(pixels(first) == pixels(try render(0.37)))
            let clear = try renderer.renderEffectsSynchronously(EffectStack(effects: [effect]),
                to: CIImage(color: .clear).cropped(to: bounds), at: 0.37, renderScale: 1)
            #expect(pixels(clear).allSatisfy { $0 == 0 })
            effect.mix = AnimatableProperty(baseValue: 0)
            #expect(pixels(try render(0.37)) == pixels(pattern))
        }
    }

    @Test func zoomOutUnfoldFillsEdgesWhileTransparentExposesThem() throws {
        let renderer = try MetalFrameRenderer()
        var effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .zoom))
        effect.parameters["mode"] = EffectParameterState(baseValue: .option("Static"))
        effect.parameters["startScale"] = EffectParameterState(baseValue: .scalar(0.5))
        func render() throws -> [UInt8] {
            pixels(try renderer.renderEffectsSynchronously(EffectStack(effects: [effect]),
                to: pattern, at: 0, renderScale: 1))
        }
        let unfolded = try render()
        #expect(stride(from: 3, to: unfolded.count, by: 4).allSatisfy { unfolded[$0] == 255 })
        // The reflected left tile stays red; an unreflected repeat is blue here.
        #expect(unfolded[10 * 4] > 240 && unfolded[10 * 4 + 2] < 10)
        effect.parameters["edges"] = EffectParameterState(baseValue: .option("Repeat Tiles"))
        let repeated = try render()
        #expect(repeated[10 * 4 + 2] > 240 && repeated[10 * 4] < 10)
        effect.parameters["edges"] = EffectParameterState(baseValue: .option("Transparent"))
        let transparent = try render()
        #expect(transparent[3] == 0)
        #expect(transparent[(20 * 80 + 40) * 4 + 3] == 255)
    }

    @Test func cameraAutoCropCoversRotatedWideFrames() throws {
        let cropScale = CameraMotionSampling.cropScale(aspect: 2, horizontal: 0.1, vertical: 0.2, rotation: .pi / 12)
        for angle in [-Double.pi / 12, 0, Double.pi / 12] {
            for x in [-0.6, 0.6] {
                for y in [-0.7, 0.7] {
                    #expect(abs(cos(angle) * x * 2 + sin(angle) * y) / cropScale <= 1.000001)
                    #expect(abs(-sin(angle) * x * 2 + cos(angle) * y) / cropScale <= 0.500001)
                }
            }
        }
        let renderer = try MetalFrameRenderer()
        for id: EffectModuleID in [.shake, .cameraWiggle] {
            var effect = try #require(EffectRegistry.shared.makeEffect(moduleID: id))
            effect.parameters["edges"] = EffectParameterState(baseValue: .option("Auto Crop"))
            effect.parameters["amount"] = EffectParameterState(baseValue: .scalar(0.2))
            effect.parameters["angle"] = EffectParameterState(baseValue: .scalar(15))
            for time in [0.0, 0.1, 0.37, 1, 2] {
                let output = pixels(try renderer.renderEffectsSynchronously(EffectStack(effects: [effect]),
                    to: pattern, at: time, renderScale: 1))
                #expect(stride(from: 3, to: output.count, by: 4).allSatisfy { output[$0] == 255 })
            }
        }
    }

    @Test func zoomOffsetMovesThePictureRight() throws {
        let renderer = try MetalFrameRenderer()
        var effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .zoom))
        effect.parameters["mode"] = EffectParameterState(baseValue: .option("Static"))
        effect.parameters["offsetX"] = EffectParameterState(baseValue: .scalar(0.25))
        let output = pixels(try renderer.renderEffectsSynchronously(EffectStack(effects: [effect]),
            to: pattern, at: 0, renderScale: 1))
        #expect(output[(20 * 80 + 50) * 4] > 240)
        #expect(output[(20 * 80 + 70) * 4 + 2] > 240)
    }

    @Test func mirrorKeepsChosenHalfAndHorizontalAxis() throws {
        let renderer = try MetalFrameRenderer()
        var effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .mirror))
        func render(_ image: CIImage) throws -> [UInt8] {
            pixels(try renderer.renderEffectsSynchronously(EffectStack(effects: [effect]),
                to: image, at: 0, renderScale: 1))
        }
        let left = try render(pattern)
        #expect(left[0] > 240 && left[(79 * 4)] > 240)
        effect.parameters["side"] = EffectParameterState(baseValue: .option("Right / Bottom"))
        let right = try render(pattern)
        #expect(right[2] > 240 && right[79 * 4 + 2] > 240)
        effect.parameters["axis"] = EffectParameterState(baseValue: .option("Horizontal"))
        effect.parameters["side"] = EffectParameterState(baseValue: .option("Left / Top"))
        let horizontal = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 0, y: 20, width: 80, height: 20))
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: bounds))
        let top = try render(horizontal)
        #expect(top[1] > 240 && top[(39 * 80) * 4 + 1] > 240)
    }

}
