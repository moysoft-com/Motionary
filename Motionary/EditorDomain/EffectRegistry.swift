// Metadata registry for built-in and future effect modules.

import Foundation

enum EffectCategory: String, CaseIterable, Identifiable, Sendable {
    case essentials = "Essentials"
    case colorGrade = "Color Grade"
    case lens = "Lens"
    case distortion = "Distortion"

    var id: String { rawValue }
}

enum EffectParameterValueType: String, Codable, Equatable, Sendable {
    case scalar
    case boolean
    case color
    case point
    case option
}

enum EffectParameterUnit: String, Codable, Equatable, Sendable {
    case normalized
    case degrees
    case unitless
}

struct EffectParameterDescriptor: Identifiable, Equatable, Sendable {
    let id: EffectParameterID
    let title: String
    let systemImage: String
    let valueType: EffectParameterValueType
    let unit: EffectParameterUnit
    let scalarRange: ClosedRange<Double>?
    let step: Double
    let fractionDigits: Int
    let defaultValue: EffectValue
    let previewValue: EffectValue
    let optionValues: [String]
    let isAnimatable: Bool

    init(
        id: EffectParameterID,
        title: String,
        systemImage: String,
        valueType: EffectParameterValueType,
        unit: EffectParameterUnit = .unitless,
        scalarRange: ClosedRange<Double>? = nil,
        step: Double = 0.01,
        fractionDigits: Int = 2,
        defaultValue: EffectValue,
        previewValue: EffectValue? = nil,
        optionValues: [String] = [],
        isAnimatable: Bool = true
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.valueType = valueType
        self.unit = unit
        self.scalarRange = scalarRange
        self.step = step
        self.fractionDigits = fractionDigits
        self.defaultValue = defaultValue
        self.previewValue = previewValue ?? defaultValue
        self.optionValues = optionValues
        self.isAnimatable = isAnimatable
    }

    func accepts(_ value: EffectValue) -> Bool {
        switch (valueType, value) {
        case (.scalar, .scalar(let scalar)):
            return scalar.isFinite && (scalarRange?.contains(scalar) ?? true)
        case (.boolean, .boolean):
            return true
        case (.color, .color(let color)):
            return [color.red, color.green, color.blue, color.alpha].allSatisfy {
                $0.isFinite && (0...1).contains($0)
            }
        case (.point, .point(let point)):
            return point.x.isFinite && point.y.isFinite
        case (.option, .option(let option)):
            return optionValues.isEmpty || optionValues.contains(option)
        default:
            return false
        }
    }
}

struct EffectModuleMigration: Sendable {
    let fromVersion: Int
    let toVersion: Int
    let migrate: @Sendable (EffectInstance) throws -> EffectInstance
}

typealias EffectRendererFactory = @Sendable () -> any EffectRenderModule

struct EffectModuleDescriptor: Identifiable, Equatable, Sendable {
    let id: EffectModuleID
    let currentVersion: Int
    let name: String
    let category: EffectCategory
    let systemImage: String
    let summary: String
    let defaultMix: Double
    let previewMix: Double
    let parameters: [EffectParameterDescriptor]
    let migrations: [EffectModuleMigration]
    let rendererFactory: EffectRendererFactory

    func descriptor(for parameterID: EffectParameterID) -> EffectParameterDescriptor? {
        parameters.first { $0.id == parameterID }
    }

    func makeRenderer() -> any EffectRenderModule {
        rendererFactory()
    }

    static func == (lhs: EffectModuleDescriptor, rhs: EffectModuleDescriptor) -> Bool {
        lhs.id == rhs.id
            && lhs.currentVersion == rhs.currentVersion
            && lhs.name == rhs.name
            && lhs.category == rhs.category
            && lhs.systemImage == rhs.systemImage
            && lhs.summary == rhs.summary
            && lhs.defaultMix == rhs.defaultMix
            && lhs.previewMix == rhs.previewMix
            && lhs.parameters == rhs.parameters
            && lhs.migrations.count == rhs.migrations.count
            && zip(lhs.migrations, rhs.migrations).allSatisfy { left, right in
                left.fromVersion == right.fromVersion
                    && left.toVersion == right.toVersion
            }
    }
}

enum EffectModuleAvailability: Equatable, Sendable {
    case available
    case unknownModule
    case unsupportedVersion(requested: Int, supported: Int)
}

enum EffectRegistryError: Error, Equatable, LocalizedError {
    case duplicateModuleID(EffectModuleID)
    case duplicateParameterID(moduleID: EffectModuleID, parameterID: EffectParameterID)
    case invalidModuleVersion(moduleID: EffectModuleID, version: Int)
    case invalidDefault(moduleID: EffectModuleID, parameterID: EffectParameterID)
    case invalidMix(moduleID: EffectModuleID, value: Double)
    case invalidMigration(moduleID: EffectModuleID, fromVersion: Int, toVersion: Int)
    case missingMigration(moduleID: EffectModuleID, fromVersion: Int)

    var errorDescription: String? {
        switch self {
        case .duplicateModuleID(let id):
            "Duplicate effect module ID: \(id.rawValue)"
        case .duplicateParameterID(let moduleID, let parameterID):
            "Duplicate parameter \(parameterID.rawValue) in \(moduleID.rawValue)"
        case .invalidModuleVersion(let moduleID, let version):
            "Invalid module version \(version) in \(moduleID.rawValue)"
        case .invalidDefault(let moduleID, let parameterID):
            "Invalid default for \(parameterID.rawValue) in \(moduleID.rawValue)"
        case .invalidMix(let moduleID, let value):
            "Invalid mix \(value) in \(moduleID.rawValue)"
        case .invalidMigration(let moduleID, let fromVersion, let toVersion):
            "Invalid effect migration in \(moduleID.rawValue): v\(fromVersion) to v\(toVersion)"
        case .missingMigration(let moduleID, let fromVersion):
            "Missing effect migration in \(moduleID.rawValue) from v\(fromVersion)"
        }
    }
}

/// The sole metadata/catalog source used by persistence, editor controls, and render-plan compilation.
struct EffectRegistry: Sendable {
    static let shared: EffectRegistry = {
        do {
            return try EffectRegistry(modules: builtInModules)
        } catch {
            preconditionFailure("Invalid built-in effect registry: \(error.localizedDescription)")
        }
    }()

    let modules: [EffectModuleDescriptor]
    private let modulesByID: [EffectModuleID: EffectModuleDescriptor]

    init(modules: [EffectModuleDescriptor]) throws {
        var indexed: [EffectModuleID: EffectModuleDescriptor] = [:]
        for module in modules {
            guard indexed[module.id] == nil else {
                throw EffectRegistryError.duplicateModuleID(module.id)
            }
            guard module.currentVersion >= 1 else {
                throw EffectRegistryError.invalidModuleVersion(
                    moduleID: module.id,
                    version: module.currentVersion
                )
            }
            guard module.defaultMix.isFinite, (0...1).contains(module.defaultMix),
                module.previewMix.isFinite, (0...1).contains(module.previewMix)
            else {
                throw EffectRegistryError.invalidMix(moduleID: module.id, value: module.defaultMix)
            }
            var parameterIDs = Set<EffectParameterID>()
            for parameter in module.parameters {
                guard parameterIDs.insert(parameter.id).inserted else {
                    throw EffectRegistryError.duplicateParameterID(
                        moduleID: module.id,
                        parameterID: parameter.id
                    )
                }
                guard parameter.accepts(parameter.defaultValue),
                    parameter.accepts(parameter.previewValue),
                    parameter.step.isFinite,
                    parameter.step > 0
                else {
                    throw EffectRegistryError.invalidDefault(
                        moduleID: module.id,
                        parameterID: parameter.id
                    )
                }
            }
            var migrationVersions = Set<Int>()
            for migration in module.migrations {
                guard migration.fromVersion >= 1,
                    migration.toVersion == migration.fromVersion + 1,
                    migration.toVersion <= module.currentVersion,
                    migrationVersions.insert(migration.fromVersion).inserted
                else {
                    throw EffectRegistryError.invalidMigration(
                        moduleID: module.id,
                        fromVersion: migration.fromVersion,
                        toVersion: migration.toVersion
                    )
                }
            }
            if module.currentVersion > 1 {
                for version in 1..<module.currentVersion
                    where !migrationVersions.contains(version)
                {
                    throw EffectRegistryError.missingMigration(
                        moduleID: module.id,
                        fromVersion: version
                    )
                }
            }
            indexed[module.id] = module
        }
        self.modules = modules
        modulesByID = indexed
    }

    func descriptor(for moduleID: EffectModuleID) -> EffectModuleDescriptor? {
        modulesByID[moduleID]
    }

    func availability(of effect: EffectInstance) -> EffectModuleAvailability {
        guard let descriptor = descriptor(for: effect.moduleID) else { return .unknownModule }
        guard effect.moduleVersion <= descriptor.currentVersion else {
            return .unsupportedVersion(
                requested: effect.moduleVersion,
                supported: descriptor.currentVersion
            )
        }
        return .available
    }

    func makeEffect(moduleID: EffectModuleID, id: UUID = UUID()) -> EffectInstance? {
        guard let descriptor = descriptor(for: moduleID) else { return nil }
        return EffectInstance(
            id: id,
            moduleID: moduleID,
            moduleVersion: descriptor.currentVersion,
            isEnabled: true,
            mix: AnimatableProperty(baseValue: descriptor.defaultMix),
            parameters: Dictionary(
                uniqueKeysWithValues: descriptor.parameters.map {
                    ($0.id.rawValue, EffectParameterState(baseValue: $0.defaultValue))
                }
            )
        )
    }

    func migrated(_ effect: EffectInstance) throws -> EffectInstance {
        guard let module = descriptor(for: effect.moduleID),
            effect.moduleVersion < module.currentVersion
        else { return effect }
        var migrated = effect
        while migrated.moduleVersion < module.currentVersion {
            guard let migration = module.migrations.first(where: {
                $0.fromVersion == migrated.moduleVersion
            }) else {
                throw EffectRegistryError.missingMigration(
                    moduleID: module.id,
                    fromVersion: migrated.moduleVersion
                )
            }
            let originalID = migrated.id
            migrated = try migration.migrate(migrated)
            migrated.id = originalID
            migrated.moduleID = module.id
            migrated.moduleVersion = migration.toVersion
        }
        return migrated
    }

    func resolvedValue(
        for parameterID: EffectParameterID,
        in effect: EffectInstance,
        at time: Double
    ) -> EffectValue? {
        guard let descriptor = descriptor(for: effect.moduleID)?.descriptor(for: parameterID) else {
            return effect.value(for: parameterID, at: time)
        }
        guard let value = effect.value(for: parameterID, at: time), descriptor.accepts(value) else {
            return descriptor.defaultValue
        }
        return value
    }

    func resolvedMix(in effect: EffectInstance, at time: Double) -> Double {
        let value = effect.mix.value(at: time)
        guard value.isFinite else {
            return descriptor(for: effect.moduleID)?.defaultMix ?? 0
        }
        return min(max(value, 0), 1)
    }
}

extension EffectRegistry {
    fileprivate static let builtInModules: [EffectModuleDescriptor] = [
        module(
            .sepia,
            "Sepia",
            .colorGrade,
            "camera.filters",
            "Warm archival tone.",
            mix: 0.6,
            previewMix: 0.78,
            renderer: { SepiaEffectRenderer() },
            parameters: [
                scalar(.warmth, "Warmth", "thermometer.sun", 0.68, 0.78),
                scalar(.contrast, "Contrast", "circle.lefthalf.filled", 0.18, 0.24),
            ]
        ),
        module(
            .noir,
            "Noir",
            .colorGrade,
            "circle.lefthalf.filled",
            "Hard monochrome contrast.",
            mix: 0.6,
            previewMix: 0.78,
            renderer: { NoirEffectRenderer() },
            parameters: [
                scalar(.contrast, "Contrast", "circle.lefthalf.filled", 0.54, 0.68),
                scalar(.grain, "Grain", "circle.grid.cross", 0.18, 0.32),
            ]
        ),
        module(
            .chrome,
            "Chrome",
            .colorGrade,
            "sparkle.magnifyingglass",
            "Cool, saturated punch.",
            mix: 0.6,
            previewMix: 0.78,
            renderer: { ChromeEffectRenderer() },
            parameters: [
                scalar(.saturation, "Color", "drop.halffull", 0.62, 0.78),
                scalar(.contrast, "Punch", "circle.lefthalf.filled", 0.34, 0.46),
            ]
        ),
        module(
            .blur,
            "Blur",
            .essentials,
            "circle.dotted",
            "Soft optical defocus.",
            mix: 0.6,
            previewMix: 0.48,
            renderer: { BlurEffectRenderer() },
            parameters: [scalar(.radius, "Radius", "circle.dotted", 0.44, 0.52)]
        ),
        module(
            .vignette,
            "Vignette",
            .essentials,
            "circle.inset.filled",
            "Focused edge falloff.",
            mix: 0.6,
            previewMix: 0.78,
            renderer: { VignetteEffectRenderer() },
            parameters: [
                scalar(.radius, "Size", "circle.inset.filled", 0.6, 0.5),
                scalar(.softness, "Softness", "circle.dashed", 0.58, 0.64),
            ]
        ),
        module(
            .cinematicBloom,
            "Cinematic Bloom",
            .lens,
            "sun.max",
            "Highlight bloom with contrast-preserving grade.",
            mix: 0.55,
            previewMix: 0.73,
            renderer: { CinematicBloomEffectRenderer() },
            parameters: [
                scalar(.radius, "Radius", "circle.dotted", 0.56, 0.64),
                scalar(.threshold, "Threshold", "sun.max", 0.58, 0.48),
                scalar(.saturation, "Color", "drop.halffull", 0.44, 0.58),
            ]
        ),
        module(
            .filmHalation,
            "Film Halation",
            .lens,
            "lightspectrum.horizontal",
            "Warm highlight bleed inspired by scanned film.",
            mix: 0.52,
            previewMix: 0.7,
            renderer: { FilmHalationEffectRenderer() },
            parameters: [
                scalar(.radius, "Bleed", "circle.dotted", 0.48, 0.58),
                scalar(.warmth, "Warmth", "thermometer.sun", 0.62, 0.74),
                scalar(.threshold, "Threshold", "sun.max", 0.56, 0.48),
            ]
        ),
        module(
            .prismSplit,
            "Prism Split",
            .distortion,
            "viewfinder",
            "Lens-edge RGB separation.",
            mix: 0.5,
            previewMix: 0.75,
            renderer: { PrismSplitEffectRenderer() },
            parameters: [
                scalar(.offset, "Offset", "arrow.left.and.right", 0.46, 0.7),
                scalar(.spread, "Spread", "viewfinder", 0.28, 0.44),
            ]
        ),
        module(
            .analogGlitch,
            "Analog Glitch",
            .distortion,
            "waveform.path.ecg",
            "Displaced scanline signal damage.",
            mix: 0.42,
            previewMix: 0.7,
            renderer: { AnalogGlitchEffectRenderer() },
            parameters: [
                scalar(.offset, "Drift", "waveform.path.ecg", 0.42, 0.66),
                scalar(.scanlines, "Scanlines", "line.3.horizontal", 0.42, 0.66),
            ]
        ),
        module(
            .bleachBypass,
            "Bleach Bypass",
            .colorGrade,
            "film",
            "Desaturated high-contrast print process.",
            mix: 0.58,
            previewMix: 0.76,
            renderer: { BleachBypassEffectRenderer() },
            parameters: [
                scalar(.contrast, "Contrast", "circle.lefthalf.filled", 0.54, 0.66),
                scalar(.saturation, "Silver", "drop.halffull", 0.68, 0.78),
                scalar(.sharpness, "Detail", "wand.and.rays", 0.36, 0.5),
            ]
        ),
        module(
            .cineTeal,
            "Cine Teal",
            .colorGrade,
            "camera.aperture",
            "Balanced teal shadows with warm skin-safe highlights.",
            mix: 0.62,
            previewMix: 0.8,
            renderer: { CineTealEffectRenderer() },
            parameters: [
                scalar(.warmth, "Highlight Warmth", "thermometer.sun", 0.5, 0.62),
                scalar(.saturation, "Color Density", "drop.halffull", 0.48, 0.6),
                scalar(.contrast, "Contrast", "circle.lefthalf.filled", 0.32, 0.44),
            ]
        ),
        module(
            .kodakPrint,
            "Kodak Print",
            .colorGrade,
            "photo.on.rectangle",
            "Warm print density with controlled saturation and soft toe.",
            mix: 0.56,
            previewMix: 0.74,
            renderer: { KodakPrintEffectRenderer() },
            parameters: [
                scalar(.warmth, "Warmth", "sun.max", 0.58, 0.7),
                scalar(.fade, "Print Fade", "rectangle.lefthalf.filled", 0.22, 0.34),
                scalar(.grain, "Grain", "circle.grid.cross", 0.2, 0.3),
            ]
        ),
        module(
            .portraSoft,
            "Portra Soft",
            .colorGrade,
            "camera.macro",
            "Creamy highlights, gentle contrast, and pastel color.",
            mix: 0.52,
            previewMix: 0.7,
            renderer: { PortraSoftEffectRenderer() },
            parameters: [
                scalar(.softness, "Softness", "camera.macro", 0.42, 0.56),
                scalar(.warmth, "Warmth", "thermometer.sun", 0.42, 0.52),
                scalar(.saturation, "Pastel", "drop.halffull", 0.32, 0.46),
            ]
        ),
        module(
            .coolFade,
            "Cool Fade",
            .colorGrade,
            "snowflake",
            "Lifted shadows with cool editorial color separation.",
            mix: 0.5,
            previewMix: 0.68,
            renderer: { CoolFadeEffectRenderer() },
            parameters: [
                scalar(.fade, "Fade", "rectangle.lefthalf.filled", 0.42, 0.56),
                scalar(.saturation, "Color", "drop.halffull", 0.32, 0.42),
                scalar(.contrast, "Contrast", "circle.lefthalf.filled", 0.18, 0.26),
            ]
        ),
        module(
            .matteContrast,
            "Matte Contrast",
            .colorGrade,
            "rectangle.lefthalf.filled",
            "Deep but filmic matte contrast without clipped blacks.",
            mix: 0.58,
            previewMix: 0.76,
            renderer: { MatteContrastEffectRenderer() },
            parameters: [
                scalar(.fade, "Black Lift", "rectangle.lefthalf.filled", 0.24, 0.34),
                scalar(.contrast, "Density", "circle.lefthalf.filled", 0.56, 0.68),
            ]
        ),
        module(
            .cleanSharpen,
            "Clean Sharpen",
            .essentials,
            "wand.and.rays",
            "Detail lift with restrained halo control.",
            mix: 0.45,
            previewMix: 0.63,
            renderer: { CleanSharpenEffectRenderer() },
            parameters: [
                scalar(.sharpness, "Detail", "wand.and.rays", 0.54, 0.7),
                scalar(.radius, "Radius", "circle.dotted", 0.28, 0.36),
            ]
        ),
        module(
            .fineGrain,
            "Fine Grain",
            .essentials,
            "circle.grid.cross",
            "Organic luma grain that scales with render resolution.",
            mix: 0.36,
            previewMix: 0.54,
            renderer: { FineGrainEffectRenderer() },
            parameters: [
                scalar(.grain, "Texture", "circle.grid.cross", 0.42, 0.7),
                scalar(.contrast, "Luma Blend", "circle.lefthalf.filled", 0.34, 0.48),
            ]
        ),
        module(
            .softGlow,
            "Soft Glow",
            .lens,
            "sparkles",
            "Subtle diffusion that keeps detail under the bloom.",
            mix: 0.48,
            previewMix: 0.66,
            renderer: { SoftGlowEffectRenderer() },
            parameters: [
                scalar(.radius, "Diffusion", "sparkles", 0.48, 0.62),
                scalar(.threshold, "Highlight Bias", "sun.max", 0.44, 0.36),
            ]
        ),
        module(
            .anamorphicFlare,
            "Anamorphic Flare",
            .lens,
            "lightspectrum.horizontal",
            "Horizontal highlight flare with tunable spread and threshold.",
            mix: 0.42,
            previewMix: 0.6,
            renderer: { AnamorphicFlareEffectRenderer() },
            parameters: [
                scalar(.spread, "Spread", "lightspectrum.horizontal", 0.58, 0.72),
                scalar(.threshold, "Threshold", "sun.max", 0.7, 0.54),
                scalar(.warmth, "Tint", "thermometer.sun", 0.34, 0.44),
            ]
        ),
        module(
            .lightLeak,
            "Light Leak",
            .lens,
            "sun.horizon",
            "Warm directional leak for transitions and overlays.",
            mix: 0.44,
            previewMix: 0.62,
            renderer: { LightLeakEffectRenderer() },
            parameters: [
                scalar(
                    .angle,
                    "Angle",
                    "angle",
                    26,
                    26,
                    range: -180...180,
                    step: 1,
                    fractionDigits: 0,
                    unit: .degrees
                ),
                scalar(.warmth, "Warmth", "thermometer.sun", 0.62, 0.72),
                scalar(.spread, "Spread", "sun.horizon", 0.5, 0.64),
            ]
        ),
        module(
            .chromaticAberration,
            "Chromatic Aberration",
            .distortion,
            "scope",
            "Controlled RGB edge shift without full-frame destruction.",
            mix: 0.36,
            previewMix: 0.54,
            renderer: { ChromaticAberrationEffectRenderer() },
            parameters: [
                scalar(.offset, "Shift", "arrow.left.and.right", 0.38, 0.58),
                scalar(.softness, "Edge Bias", "scope", 0.58, 0.72),
            ]
        ),
        module(
            .barrelWarp,
            "Barrel Warp",
            .distortion,
            "circle.grid.3x3.circle",
            "Lens barrel or pincushion warp with soft edge falloff.",
            mix: 0.34,
            previewMix: 0.52,
            renderer: { BarrelWarpEffectRenderer() },
            parameters: [
                scalar(
                    .warp,
                    "Warp",
                    "circle.grid.3x3.circle",
                    0.32,
                    0.48,
                    range: -1...1
                ),
                scalar(.softness, "Edge Falloff", "circle.dashed", 0.45, 0.56),
            ]
        ),
    ]

    private static func module(
        _ id: EffectModuleID,
        _ name: String,
        _ category: EffectCategory,
        _ systemImage: String,
        _ summary: String,
        mix: Double,
        previewMix: Double,
        renderer: @escaping EffectRendererFactory,
        migrations: [EffectModuleMigration] = [],
        parameters: [EffectParameterDescriptor]
    ) -> EffectModuleDescriptor {
        EffectModuleDescriptor(
            id: id,
            currentVersion: 1,
            name: name,
            category: category,
            systemImage: systemImage,
            summary: summary,
            defaultMix: mix,
            previewMix: previewMix,
            parameters: parameters,
            migrations: migrations,
            rendererFactory: renderer
        )
    }

    private static func scalar(
        _ id: EffectParameterID,
        _ title: String,
        _ systemImage: String,
        _ defaultValue: Double,
        _ previewValue: Double,
        range: ClosedRange<Double> = 0...1,
        step: Double = 0.01,
        fractionDigits: Int = 2,
        unit: EffectParameterUnit = .normalized
    ) -> EffectParameterDescriptor {
        EffectParameterDescriptor(
            id: id,
            title: title,
            systemImage: systemImage,
            valueType: .scalar,
            unit: unit,
            scalarRange: range,
            step: step,
            fractionDigits: fractionDigits,
            defaultValue: .scalar(defaultValue),
            previewValue: .scalar(previewValue)
        )
    }
}
