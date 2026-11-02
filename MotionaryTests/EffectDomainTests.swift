// Focused tests for schema-11 effect persistence, registry, and timeline operations.

import Foundation
import CoreImage
import Testing

@testable import Motionary

struct EffectDomainTests {
    @Test func angleParametersPreserveMultipleTurnsAndRejectNonfiniteValues() throws {
        let registry = EffectRegistry.shared
        for module in registry.modules {
            for parameter in module.parameters where parameter.unit == .degrees {
                var effect = try #require(registry.makeEffect(moduleID: module.id))
                for degrees in [-1080.0, -181, 181, 1080, 9999] {
                    effect.parameters[parameter.id.rawValue] = EffectParameterState(baseValue: .scalar(degrees))
                    #expect(registry.resolvedValue(for: parameter.id, in: effect, at: 0) == .scalar(degrees))
                }
                for degrees in [Double.nan, .infinity, -.infinity] {
                    #expect(!parameter.accepts(.scalar(degrees)))
                }
            }
        }
        let amount = try #require(registry.descriptor(for: .waveWarp)?.descriptor(for: .amount))
        #expect(!amount.accepts(.scalar(2)))
    }

    @Test func cyclicAnglesWrapOnlyAfterKeyframeInterpolation() throws {
        let renderer = OpticalBlurEffectRenderer(moduleID: .directionalBlur)
        var effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .directionalBlur))
        effect.parameters[EffectParameterID.angle.rawValue] = EffectParameterState(
            baseValue: .scalar(0), keyframes: [
                Keyframe(time: 0, value: .scalar(0)),
                Keyframe(time: 2, value: .scalar(720)),
            ]
        )
        #expect(EffectRegistry.shared.resolvedValue(for: .angle, in: effect, at: 1) == .scalar(360))
        #expect(renderer.cyclicDegrees(.angle, in: effect, at: 1) == 0)
        #expect(renderer.cyclicDegrees(.angle, in: effect, at: 0.5) == 180)
        effect.parameters[EffectParameterID.angle.rawValue] = EffectParameterState(baseValue: .scalar(-1085))
        #expect(renderer.cyclicDegrees(.angle, in: effect, at: 0) == -5)
    }

    @Test func builtInRegistryContainsFortyThreeValidModules() throws {
        let registry = EffectRegistry.shared

        #expect(registry.modules.count == 43)
        #expect(Set(registry.modules.map(\.id)).count == registry.modules.count)
        for module in registry.modules {
            #expect(module.currentVersion == 1)
            #expect((0...1).contains(module.defaultMix))
            #expect(Set(module.parameters.map(\.id)).count == module.parameters.count)
            #expect(module.makeRenderer().moduleID == module.id)
            let effect = try #require(registry.makeEffect(moduleID: module.id))
            #expect(effect.parameters.count == module.parameters.count)
            let encoded = try JSONEncoder().encode(effect)
            let restored = try JSONDecoder().decode(EffectInstance.self, from: encoded)
            #expect(restored == effect)
            #expect(registry.availability(of: effect) == .available)
            var newerEffect = effect
            newerEffect.moduleVersion += 1
            #expect(
                registry.availability(of: newerEffect)
                    == .unsupportedVersion(
                        requested: newerEffect.moduleVersion,
                        supported: module.currentVersion
                    )
            )
        }
    }

    @Test func schemaTenStackMigratesAllBuiltInsAndMaterializesDefaults() throws {
        let mappings: [(String, EffectModuleID)] = [
            ("Sepia", .sepia), ("Noir", .noir), ("Chrome", .chrome),
            ("Blur", .blur), ("Vignette", .vignette),
            ("Cinematic Bloom", .cinematicBloom), ("Film Halation", .filmHalation),
            ("Prism Split", .prismSplit), ("Analog Glitch", .analogGlitch),
            ("Bleach Bypass", .bleachBypass), ("Cine Teal", .cineTeal),
            ("Kodak Print", .kodakPrint), ("Portra Soft", .portraSoft),
            ("Cool Fade", .coolFade), ("Matte Contrast", .matteContrast),
            ("Clean Sharpen", .cleanSharpen), ("Fine Grain", .fineGrain),
            ("Soft Glow", .softGlow), ("Anamorphic Flare", .anamorphicFlare),
            ("Light Leak", .lightLeak), ("Chromatic Aberration", .chromaticAberration),
            ("Barrel Warp", .barrelWarp),
        ]
        let mixKeyframeID = UUID()
        let parameterKeyframeID = UUID()
        let legacyMix = AnimatableProperty(
            baseValue: 0.37,
            keyframes: [
                Keyframe(
                    id: mixKeyframeID,
                    time: 1.25,
                    value: 0.81,
                    interpolation: .hold
                )
            ]
        )
        let legacyParameter = AnimatableProperty(
            baseValue: 0.22,
            keyframes: [
                Keyframe(
                    id: parameterKeyframeID,
                    time: 0.75,
                    value: 0.66,
                    interpolation: .linear
                )
            ]
        )
        let mixObject = try jsonObject(legacyMix)
        let parameterObject = try jsonObject(legacyParameter)
        var ids: [UUID] = []
        let effects: [[String: Any]] = mappings.enumerated().map { index, mapping in
            let id = UUID()
            ids.append(id)
            return [
                "id": id.uuidString,
                "kind": mapping.0,
                "isEnabled": index.isMultiple(of: 2),
                "intensity": mixObject,
                "parameters": index == 0 ? ["future-v10-parameter": parameterObject] : [:],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["effects": effects])

        let stack = try JSONDecoder().decode(EffectStack.self, from: data)

        #expect(stack.effects.map(\.id) == ids)
        #expect(stack.effects.map(\.moduleID) == mappings.map(\.1))
        #expect(stack.effects.map(\.isEnabled) == mappings.indices.map { $0.isMultiple(of: 2) })
        #expect(stack.effects.allSatisfy { $0.mix.baseValue == 0.37 })
        #expect(stack.effects.allSatisfy { $0.mix.keyframes.first?.id == mixKeyframeID })
        #expect(stack.effects.allSatisfy { $0.seed == EffectInstance.deterministicSeed(for: $0.id) })
        #expect(stack.effects[0].parameters["future-v10-parameter"]?.keyframes.first?.id == parameterKeyframeID)
        #expect(stack.effects[3].scalarValue(for: .radius, at: 0) == 0.44)
        #expect(stack.effects[19].scalarValue(for: .angle, at: 0) == 26)
    }

    @Test func schemaElevenRoundTripPreservesTypedAndOpaqueValues() throws {
        let unknownEnvelope: JSONValue = .object([
            "type": .string("curve-v2"),
            "value": .object([
                "knots": .array([.number(0), .number(0.4), .number(1)]),
                "label": .string("future"),
            ]),
        ])
        let effect = EffectInstance(
            moduleID: "com.example.effect.future",
            moduleVersion: 9,
            mix: AnimatableProperty(baseValue: 0.42),
            seed: 123_456,
            parameters: [
                "scalar": EffectParameterState(baseValue: .scalar(0.2)),
                "boolean": EffectParameterState(baseValue: .boolean(true)),
                "color": EffectParameterState(
                    baseValue: .color(RGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4))
                ),
                "point": EffectParameterState(baseValue: .point(EffectPoint(x: -0.2, y: 0.8))),
                "option": EffectParameterState(baseValue: .option("cinematic")),
                "future": EffectParameterState(baseValue: .opaque(unknownEnvelope)),
            ]
        )
        let stack = EffectStack(effects: [effect])

        let decoded = try JSONDecoder().decode(
            EffectStack.self,
            from: JSONEncoder().encode(stack)
        )

        #expect(decoded == stack)
        #expect(EffectRegistry.shared.availability(of: decoded.effects[0]) == .unknownModule)
        #expect(decoded.effects[0].parameters["future"]?.baseValue == .opaque(unknownEnvelope))
    }

    @Test func opaqueNumberRoundTripPreservesLargeHighPrecisionDecimal() throws {
        let number = try #require(
            Decimal(
                string: "1234567890123456789012345678.123456789",
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
        let value = EffectValue.opaque(.object([
            "type": .string("decimal-v2"),
            "value": .number(number),
        ]))

        let decoded = try JSONDecoder().decode(
            EffectValue.self,
            from: JSONEncoder().encode(value)
        )

        #expect(decoded == value)
    }

    @Test func unknownParameterKeyframesSurviveSplitAndTrim() throws {
        let firstID = UUID()
        let secondID = UUID()
        let futureState = EffectParameterState(
            baseValue: .opaque(.object(["type": .string("future"), "value": .number(0)])),
            keyframes: [
                Keyframe(
                    id: firstID,
                    time: 1,
                    value: .opaque(.object(["type": .string("future"), "value": .number(1)])),
                    interpolation: .hold
                ),
                Keyframe(
                    id: secondID,
                    time: 3,
                    value: .opaque(.object(["type": .string("future"), "value": .number(2)]))
                ),
            ]
        )
        let stack = EffectStack(effects: [
            EffectInstance(
                moduleID: "com.example.effect.future",
                moduleVersion: 2,
                parameters: ["future": futureState]
            )
        ])

        let split = stack.splittingAnimations(at: 2)
        let leftFrames = try #require(split.left.effects[0].parameters["future"]?.keyframes)
        let rightFrames = try #require(split.right.effects[0].parameters["future"]?.keyframes)

        #expect(leftFrames.contains { $0.id == firstID && $0.time == 1 })
        #expect(rightFrames.contains { $0.id == secondID && $0.time == 1 })
        #expect(leftFrames.last?.time == 2)
        #expect(rightFrames.first?.time == 0)

        var trimmed = stack
        trimmed.trimAnimationsAtStart(by: 1, oldDuration: 4)
        #expect(trimmed.effects[0].parameters["future"]?.keyframes.first?.time == 0)
        trimmed.trimAnimationsAtEnd(newDuration: 1, oldDuration: 3)
        #expect(trimmed.effects[0].parameters["future"]?.keyframes.last?.time == 1)
    }

    @Test func creativeEffectsRenderOnGPUAndRespectMixAndTransparency() throws {
        let renderer = try MetalFrameRenderer()
        let context = CIContext()
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        let input = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)).cropped(to: bounds)
        let transparent = CIImage(color: .clear).cropped(to: bounds)
        func pixels(_ image: CIImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
            context.render(image, toBitmap: &bytes, rowBytes: 64 * 4, bounds: bounds,
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return bytes
        }
        for id: EffectModuleID in [.lightSweep, .ribbedGlass, .dither, .halftone, .colorSplash, .neonEdges] {
            var effect = try #require(EffectRegistry.shared.makeEffect(moduleID: id))
            let output = try renderer.renderEffectsSynchronously(EffectStack(effects: [effect]),
                to: input, at: 0.3, renderScale: 1)
            #expect(output.extent == bounds)
            let rendered = pixels(output)
            #expect(stride(from: 3, to: rendered.count, by: 4).allSatisfy { rendered[$0] == 255 })
            let clearOutput = try renderer.renderEffectsSynchronously(EffectStack(effects: [effect]),
                to: transparent, at: 0.3, renderScale: 1)
            #expect(pixels(clearOutput).allSatisfy { $0 == 0 })
            let translucent = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 0.5)).cropped(to: bounds)
            let translucentOutput = try renderer.renderEffectsSynchronously(EffectStack(effects: [effect]),
                to: translucent, at: 0.3, renderScale: 1)
            let translucentPixels = pixels(translucentOutput)
            #expect(stride(from: 3, to: translucentPixels.count, by: 4).allSatisfy {
                abs(Int(translucentPixels[$0]) - 128) <= 1
            })
            let gradient = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 64, y: 64),
                "inputColor0": CIColor(red: 1, green: 0, blue: 0),
                "inputColor1": CIColor(red: 0, green: 0.2, blue: 1),
            ])!.outputImage!.cropped(to: bounds)
            let patternedOutput = try renderer.renderEffectsSynchronously(EffectStack(effects: [effect]),
                to: gradient, at: 0.3, renderScale: 1)
            let difference = zip(pixels(patternedOutput), pixels(gradient)).reduce(0) {
                $0 + abs(Int($1.0) - Int($1.1))
            }
            #expect(difference > 100, "Every creative effect must visibly change a nonuniform source")
            effect.mix = AnimatableProperty(baseValue: 0)
            let bypass = try renderer.renderEffectsSynchronously(EffectStack(effects: [effect]),
                to: input, at: 0.3, renderScale: 1)
            #expect(pixels(bypass) == pixels(input))
        }
    }

    @Test func colorSplashKeepsRedAndDesaturatesBlue() throws {
        let renderer = try MetalFrameRenderer()
        let bounds = CGRect(x: 0, y: 0, width: 32, height: 16)
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: bounds)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let effect = try #require(EffectRegistry.shared.makeEffect(moduleID: .colorSplash))
        let output = try renderer.renderEffectsSynchronously(EffectStack(effects: [effect]),
            to: red.composited(over: blue), at: 0, renderScale: 1)
        var bytes = [UInt8](repeating: 0, count: 32 * 16 * 4)
        CIContext().render(output, toBitmap: &bytes, rowBytes: 32 * 4, bounds: bounds,
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        #expect(bytes[0] > 240 && bytes[1] < 10 && bytes[2] < 10)
        let blueIndex = 24 * 4
        #expect(abs(Int(bytes[blueIndex]) - Int(bytes[blueIndex + 1])) <= 1)
        #expect(abs(Int(bytes[blueIndex]) - Int(bytes[blueIndex + 2])) <= 1)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}
