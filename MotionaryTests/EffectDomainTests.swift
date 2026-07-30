// Focused tests for schema-11 effect persistence, registry, and timeline operations.

import Foundation
import Testing

@testable import Motionary

struct EffectDomainTests {
    @Test func builtInRegistryContainsTwentyTwoValidModules() throws {
        let registry = EffectRegistry.shared

        #expect(registry.modules.count == 22)
        #expect(Set(registry.modules.map(\.id)).count == registry.modules.count)
        for module in registry.modules {
            #expect(module.currentVersion == 1)
            #expect((0...1).contains(module.defaultMix))
            #expect(Set(module.parameters.map(\.id)).count == module.parameters.count)
            #expect(module.makeRenderer().moduleID == module.id)
            let effect = try #require(registry.makeEffect(moduleID: module.id))
            #expect(effect.parameters.count == module.parameters.count)
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

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}
