// Metadata registry for built-in and future effect modules.

import Foundation

enum EffectCategory: String, CaseIterable, Identifiable, Sendable {
    case essentials = "Essentials"
    case colorGrade = "Color Grade"
    case lens = "Lens"
    case distortion = "Distortion"

    var id: String { rawValue }

    var showcaseImageAssetName: String {
        switch self {
        case .essentials: "EffectsShowcaseEssentials"
        case .colorGrade: "EffectsShowcaseColorGrade"
        case .lens: "EffectsShowcaseLens"
        case .distortion: "EffectsShowcaseDistortion"
        }
    }
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
            // Degree controls support multiple turns. Their range describes
            // the nominal control span, not a validity limit for animations.
            return scalar.isFinite && (unit == .degrees || (scalarRange?.contains(scalar) ?? true))
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

/// Internal sampling requirements, independent of editable effect parameters.
enum EffectEdgeMode: UInt32, Equatable, Sendable {
    case transparent = 0
    case clamp = 1
    case repeatTile = 2
    case unfold = 3
}

struct EffectRenderConfiguration: Equatable, Sendable {
    var edgeMode: EffectEdgeMode = .transparent
    var usesTemporalFrames: Bool = false
    var usesDisplacementMap: Bool = false
}

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
    var renderConfiguration: EffectRenderConfiguration = .init()

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
            && lhs.renderConfiguration == rhs.renderConfiguration
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
            mix: 1.0,
            previewMix: 1.0,
            renderer: { SepiaEffectRenderer() },
            parameters: [
                scalar(.warmth, "Warmth", "thermometer.sun", 0.78, 0.78),
                scalar(.contrast, "Contrast", "circle.lefthalf.filled", 0.24, 0.24),
            ]
        ),
        module(
            .noir,
            "Noir",
            .colorGrade,
            "circle.lefthalf.filled",
            "Hard monochrome contrast.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { NoirEffectRenderer() },
            parameters: [
                scalar(.contrast, "Contrast", "circle.lefthalf.filled", 0.68, 0.68),
                scalar(.grain, "Grain", "circle.grid.cross", 0.32, 0.32),
            ]
        ),
        module(
            .chrome,
            "Chrome",
            .colorGrade,
            "sparkle.magnifyingglass",
            "Cool, saturated punch.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { ChromeEffectRenderer() },
            parameters: [
                scalar(.saturation, "Color", "drop.halffull", 0.78, 0.78),
                scalar(.contrast, "Punch", "circle.lefthalf.filled", 0.46, 0.46),
            ]
        ),
        module(
            .blur,
            "Blur",
            .essentials,
            "circle.dotted",
            "Soft optical defocus.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { BlurEffectRenderer() },
            parameters: [scalar(.radius, "Radius", "circle.dotted", 0.14, 0.14)]
        ),
        module(
            .vignette,
            "Vignette",
            .essentials,
            "circle.inset.filled",
            "Focused edge falloff.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { VignetteEffectRenderer() },
            parameters: [
                scalar(.radius, "Size", "circle.inset.filled", 0.5, 0.5),
                scalar(.softness, "Softness", "circle.dashed", 0.64, 0.64),
            ]
        ),
        module(
            .cinematicBloom,
            "Cinematic Bloom",
            .lens,
            "sun.max",
            "Highlight bloom with contrast-preserving grade.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { CinematicBloomEffectRenderer() },
            parameters: [
                scalar(.radius, "Radius", "circle.dotted", 0.64, 0.64),
                scalar(.threshold, "Threshold", "sun.max", 0.48, 0.48),
                scalar(.saturation, "Color", "drop.halffull", 0.58, 0.58),
            ]
        ),
        module(
            .filmHalation,
            "Film Halation",
            .lens,
            "lightspectrum.horizontal",
            "Warm highlight bleed inspired by scanned film.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { FilmHalationEffectRenderer() },
            parameters: [
                scalar(.radius, "Bleed", "circle.dotted", 0.58, 0.58),
                scalar(.warmth, "Warmth", "thermometer.sun", 0.74, 0.74),
                scalar(.threshold, "Threshold", "sun.max", 0.48, 0.48),
            ]
        ),
        module(
            .prismSplit,
            "Prism Split",
            .distortion,
            "viewfinder",
            "Lens-edge RGB separation.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { PrismSplitEffectRenderer() },
            renderConfiguration: .init(edgeMode: .unfold),
            parameters: [
                scalar(.offset, "Offset", "arrow.left.and.right", 0.85, 0.85),
                scalar(.spread, "Spread", "viewfinder", 0.85, 0.85),
            ]
        ),
        module(
            .analogGlitch,
            "Analog Glitch",
            .distortion,
            "waveform.path.ecg",
            "Displaced scanline signal damage.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { AnalogGlitchEffectRenderer() },
            renderConfiguration: .init(edgeMode: .unfold),
            parameters: [
                scalar(.offset, "Drift", "waveform.path.ecg", 0.66, 0.66),
                scalar(.scanlines, "Scanlines", "line.3.horizontal", 0.66, 0.66),
            ]
        ),
        module(
            .bleachBypass,
            "Bleach Bypass",
            .colorGrade,
            "film",
            "Desaturated high-contrast print process.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { BleachBypassEffectRenderer() },
            renderConfiguration: .init(edgeMode: .unfold),
            parameters: [
                scalar(.contrast, "Contrast", "circle.lefthalf.filled", 0.66, 0.66),
                scalar(.saturation, "Silver", "drop.halffull", 0.78, 0.78),
                scalar(.sharpness, "Detail", "wand.and.rays", 0.5, 0.5),
            ]
        ),
        module(
            .cineTeal,
            "Cine Teal",
            .colorGrade,
            "camera.aperture",
            "Balanced teal shadows with warm skin-safe highlights.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { CineTealEffectRenderer() },
            parameters: [
                scalar(.warmth, "Highlight Warmth", "thermometer.sun", 0.62, 0.62),
                scalar(.saturation, "Color Density", "drop.halffull", 0.6, 0.6),
                scalar(.contrast, "Contrast", "circle.lefthalf.filled", 0.44, 0.44),
            ]
        ),
        module(
            .kodakPrint,
            "Kodak Print",
            .colorGrade,
            "photo.on.rectangle",
            "Warm print density with controlled saturation and soft toe.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { KodakPrintEffectRenderer() },
            parameters: [
                scalar(.warmth, "Warmth", "sun.max", 0.7, 0.7),
                scalar(.fade, "Print Fade", "rectangle.lefthalf.filled", 0.34, 0.34),
                scalar(.grain, "Grain", "circle.grid.cross", 0.3, 0.3),
            ]
        ),
        module(
            .portraSoft,
            "Portra Soft",
            .colorGrade,
            "camera.macro",
            "Creamy highlights, gentle contrast, and pastel color.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { PortraSoftEffectRenderer() },
            parameters: [
                scalar(.softness, "Softness", "camera.macro", 0.56, 0.56),
                scalar(.warmth, "Warmth", "thermometer.sun", 0.52, 0.52),
                scalar(.saturation, "Pastel", "drop.halffull", 0.46, 0.46),
            ]
        ),
        module(
            .coolFade,
            "Cool Fade",
            .colorGrade,
            "snowflake",
            "Lifted shadows with cool editorial color separation.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { CoolFadeEffectRenderer() },
            parameters: [
                scalar(.fade, "Fade", "rectangle.lefthalf.filled", 0.56, 0.56),
                scalar(.saturation, "Color", "drop.halffull", 0.42, 0.42),
                scalar(.contrast, "Contrast", "circle.lefthalf.filled", 0.26, 0.26),
            ]
        ),
        module(
            .matteContrast,
            "Matte Contrast",
            .colorGrade,
            "rectangle.lefthalf.filled",
            "Deep but filmic matte contrast without clipped blacks.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { MatteContrastEffectRenderer() },
            parameters: [
                scalar(.fade, "Black Lift", "rectangle.lefthalf.filled", 0.34, 0.34),
                scalar(.contrast, "Density", "circle.lefthalf.filled", 0.68, 0.68),
            ]
        ),
        module(
            .cleanSharpen,
            "Clean Sharpen",
            .essentials,
            "wand.and.rays",
            "Detail lift with restrained halo control.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { CleanSharpenEffectRenderer() },
            parameters: [
                scalar(.sharpness, "Detail", "wand.and.rays", 0.7, 0.7),
                scalar(.radius, "Radius", "circle.dotted", 0.36, 0.36),
            ]
        ),
        module(
            .fineGrain,
            "Fine Grain",
            .essentials,
            "circle.grid.cross",
            "Organic luma grain that scales with render resolution.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { FineGrainEffectRenderer() },
            parameters: [
                scalar(.grain, "Texture", "circle.grid.cross", 0.7, 0.7),
                scalar(.contrast, "Luma Blend", "circle.lefthalf.filled", 0.48, 0.48),
            ]
        ),
        module(
            .softGlow,
            "Soft Glow",
            .lens,
            "sparkles",
            "Subtle diffusion that keeps detail under the bloom.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { SoftGlowEffectRenderer() },
            parameters: [
                scalar(.radius, "Diffusion", "sparkles", 0.62, 0.62),
                scalar(.threshold, "Highlight Bias", "sun.max", 0.36, 0.36),
            ]
        ),
        module(
            .anamorphicFlare,
            "Anamorphic Flare",
            .lens,
            "lightspectrum.horizontal",
            "Horizontal highlight flare with tunable spread and threshold.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { AnamorphicFlareEffectRenderer() },
            parameters: [
                scalar(.spread, "Spread", "lightspectrum.horizontal", 0.72, 0.72),
                scalar(.threshold, "Threshold", "sun.max", 0.22, 0.22),
                scalar(.warmth, "Tint", "thermometer.sun", 0.44, 0.44),
            ]
        ),
        module(
            .lightLeak,
            "Light Leak",
            .lens,
            "sun.horizon",
            "Warm directional leak for transitions and overlays.",
            mix: 1.0,
            previewMix: 1.0,
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
                scalar(.warmth, "Warmth", "thermometer.sun", 0.72, 0.72),
                scalar(.spread, "Spread", "sun.horizon", 0.64, 0.64),
            ]
        ),
        module(
            .chromaticAberration,
            "Chromatic Aberration",
            .distortion,
            "scope",
            "Controlled RGB edge shift without full-frame destruction.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { ChromaticAberrationEffectRenderer() },
            renderConfiguration: .init(edgeMode: .unfold),
            parameters: [
                scalar(.offset, "Shift", "arrow.left.and.right", 0.85, 0.85),
                scalar(.softness, "Edge Bias", "scope", 0.95, 0.95),
            ]
        ),
        module(
            .barrelWarp,
            "Barrel Warp",
            .distortion,
            "circle.grid.3x3.circle",
            "Geometric barrel or pincushion distortion.",
            mix: 1.0,
            previewMix: 1.0,
            renderer: { BarrelWarpEffectRenderer() },
            renderConfiguration: .init(edgeMode: .unfold),
            parameters: [
                scalar(
                    .warp,
                    "Warp",
                    "circle.grid.3x3.circle",
                    0.48,
                    0.48,
                    range: -1...1
                ),
            ]
        ),
    ] + extendedModules + creativeModules + motionModules

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
        renderConfiguration: EffectRenderConfiguration = .init(),
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
            rendererFactory: renderer,
            renderConfiguration: renderConfiguration
        )
    }

    private static func option(
        _ id: EffectParameterID, _ title: String, _ values: [String], defaultValue: String
    ) -> EffectParameterDescriptor {
        EffectParameterDescriptor(id: id, title: title, systemImage: "slider.horizontal.3",
            valueType: .option, defaultValue: .option(defaultValue),
            optionValues: values, isAnimatable: false)
    }

    private static func edges(autoCrop: Bool = false) -> EffectParameterDescriptor {
        option("edges", "Edges",
            ["Unfold", "Repeat Tiles", "Transparent", "Clamp"] + (autoCrop ? ["Auto Crop"] : []),
            defaultValue: "Unfold")
    }

    private static let motionModules: [EffectModuleDescriptor] = [
        module(.shake, "Shake", .essentials, "waveform.path",
            "Fast camera impacts with adjustable axes, rotation and decay.", mix: 1, previewMix: 1,
            renderer: { CameraMotionEffectRenderer(moduleID: .shake) }, parameters: [
                scalar(.amount, "Strength", "waveform", 0.025, 0.025, range: 0...0.3),
                scalar(.frequency, "Frequency (Hz)", "waveform.path", 16, 16, range: 0...40, step: 0.1, unit: .unitless),
                scalar("horizontal", "Horizontal", "arrow.left.and.right", 1, 1),
                scalar("vertical", "Vertical", "arrow.up.and.down", 1, 1),
                scalar(.angle, "Rotation", "angle", 1.2, 1.2, range: 0...30, step: 0.1, unit: .degrees),
                scalar(.decay, "Decay", "line.diagonal", 0, 0, range: 0...10, unit: .unitless),
                scalar("scale", "Zoom", "plus.magnifyingglass", 1.05, 1.05, range: 1...2, unit: .unitless),
                scalar("seed", "Variation", "dice", 0, 0, range: 0...999, step: 1, fractionDigits: 0, unit: .unitless),
                edges(autoCrop: true)
            ]),
        module(.cameraWiggle, "Camera Wiggle", .essentials, "camera",
            "Smooth, organic handheld drift with independent position and rotation.", mix: 1, previewMix: 1,
            renderer: { CameraMotionEffectRenderer(moduleID: .cameraWiggle) }, parameters: [
                scalar(.amount, "Strength", "waveform", 0.012, 0.012, range: 0...0.2),
                scalar(.frequency, "Frequency (Hz)", "waveform.path", 0.7, 0.7, range: 0...8, step: 0.1, unit: .unitless),
                scalar("horizontal", "Horizontal", "arrow.left.and.right", 1, 1),
                scalar("vertical", "Vertical", "arrow.up.and.down", 1, 1),
                scalar(.angle, "Rotation", "angle", 0.6, 0.6, range: 0...15, step: 0.1, unit: .degrees),
                scalar("scale", "Zoom", "plus.magnifyingglass", 1.04, 1.04, range: 1...2, unit: .unitless),
                scalar("seed", "Variation", "dice", 0, 0, range: 0...999, step: 1, fractionDigits: 0, unit: .unitless),
                edges(autoCrop: true)
            ]),
        module(.zoom, "Zoom", .essentials, "plus.magnifyingglass",
            "Animated zoom in, zoom out or pulse, with mirrored tiles and framing offsets.", mix: 1, previewMix: 1,
            renderer: { CameraMotionEffectRenderer(moduleID: .zoom) }, parameters: [
                option("mode", "Direction", ["In", "Out", "Pulse", "Static"], defaultValue: "In"),
                scalar("startScale", "Minimum Zoom", "minus.magnifyingglass", 1, 1.3, range: 0.1...5, unit: .unitless),
                scalar("endScale", "Maximum Zoom", "plus.magnifyingglass", 1.3, 1.3, range: 0.1...5, unit: .unitless),
                scalar("duration", "Duration (s)", "clock", 1, 1, range: 0.05...30, unit: .unitless),
                option("easing", "Easing", ["Smooth", "Linear", "Ease In", "Ease Out"], defaultValue: "Smooth"),
                centerParameter(),
                scalar("offsetX", "Offset X", "arrow.left.and.right", 0, 0, range: -1...1),
                scalar("offsetY", "Offset Y", "arrow.up.and.down", 0, 0, range: -1...1),
                edges()
            ]),
        module(.mirror, "Mirror", .distortion, "arrow.left.and.right.righttriangle.left.righttriangle.right",
            "Reflect one side across a movable vertical, horizontal or angled axis.", mix: 1, previewMix: 1,
            renderer: { CameraMotionEffectRenderer(moduleID: .mirror) }, parameters: [
                option("axis", "Axis", ["Vertical", "Horizontal", "Custom"], defaultValue: "Vertical"),
                option("side", "Keep Side", ["Left / Top", "Right / Bottom"], defaultValue: "Left / Top"),
                scalar(.angle, "Axis Angle", "angle", 0, 0, range: -180...180, step: 1, fractionDigits: 0, unit: .degrees),
                centerParameter(), edges()
            ]),
        module(.motionBlur, "Motion Blur", .lens, "camera.shutter.button",
            "Blur the object’s animated position, rotation and scale over the shutter interval.",
            mix: 1, previewMix: 1, renderer: { MotionBlurEffectRenderer() },
            renderConfiguration: .init(usesTemporalFrames: true), parameters: [
                option("motion", "Include Motion", ["All", "Position", "Rotation", "Scale", "Position + Rotation", "Position + Scale", "Rotation + Scale", "None"], defaultValue: "All"),
                scalar("shutter", "Shutter Angle", "camera.shutter.button", 180, 270,
                    range: 0...720, step: 1, fractionDigits: 0, unit: .unitless),
                scalar(.samples, "Samples", "square.3.layers.3d", 12, 12,
                    range: 2...32, step: 1, fractionDigits: 0, unit: .unitless)
            ])
    ]

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


extension EffectRegistry {
    private static func centerParameter() -> EffectParameterDescriptor {
        EffectParameterDescriptor(id: .center, title: "Center", systemImage: "scope",
            valueType: .point, defaultValue: .point(EffectPoint(x: 0.5, y: 0.5)))
    }

    private static func colorParameter(_ id: EffectParameterID, _ title: String, _ color: RGBAColor) -> EffectParameterDescriptor {
        EffectParameterDescriptor(id: id, title: title, systemImage: "paintpalette",
            valueType: .color, defaultValue: .color(color))
    }

    private static let extendedModules: [EffectModuleDescriptor] = [
        module(.waveWarp, "Wave Warp", .distortion, "water.waves", "Animated sine waves bend the image.", mix: 1, previewMix: 1,
            renderer: { SpatialEffectRenderer(moduleID: .waveWarp, kind: .waveWarp) },
            renderConfiguration: .init(edgeMode: .unfold), parameters: [
                scalar(.amount, "Amount", "waveform", 0.055, 0.055, range: 0...0.3),
                scalar(.wavelength, "Wavelength", "arrow.left.and.right", 0.28, 0.28, range: 0.02...1),
                scalar(.angle, "Angle", "angle", 0, 0, range: -180...180, step: 1, fractionDigits: 0, unit: .degrees),
                scalar(.speed, "Speed", "speedometer", 0.5, 0.5, range: -3...3),
            ]),
        module(.twirl, "Twirl", .distortion, "hurricane", "Twist a region around an adjustable center.", mix: 1, previewMix: 1,
            renderer: { SpatialEffectRenderer(moduleID: .twirl, kind: .twirl) },
            renderConfiguration: .init(edgeMode: .unfold), parameters: [
                scalar(.angle, "Twist", "arrow.trianglehead.2.clockwise.rotate.90", 140, 140, range: -720...720, step: 1, fractionDigits: 0, unit: .degrees),
                scalar(.radius, "Radius", "circle.dotted", 0.65, 0.65, range: 0.01...1.5), centerParameter(),
            ]),
        module(.pixelate, "Pixelate", .essentials, "square.grid.3x3.fill", "A crisp pixel grid, independent of output resolution.", mix: 1, previewMix: 1,
            renderer: { SpatialEffectRenderer(moduleID: .pixelate, kind: .pixelate) },
            renderConfiguration: .init(edgeMode: .clamp), parameters: [
                scalar(.amount, "Pixel Size", "square.grid.3x3", 0.045, 0.045, range: 0.002...0.25),
            ]),
        module(.posterize, "Posterize", .colorGrade, "square.stack.3d.up.fill", "Reduce the image to distinct tonal steps.", mix: 1, previewMix: 1,
            renderer: { SpatialEffectRenderer(moduleID: .posterize, kind: .posterize) }, parameters: [
                scalar(.levels, "Levels", "line.3.horizontal", 4, 4, range: 2...32, step: 1, fractionDigits: 0, unit: .unitless),
            ]),
        module(.directionalBlur, "Directional Blur", .lens, "line.diagonal", "Directional streaks with mirrored image edges.", mix: 1, previewMix: 1,
            renderer: { OpticalBlurEffectRenderer(moduleID: .directionalBlur) },
            renderConfiguration: .init(edgeMode: .unfold), parameters: [
                scalar(.amount, "Length", "arrow.left.and.right", 0.06, 0.06, range: 0...0.3),
                scalar(.angle, "Angle", "angle", 35, 35, range: -180...180, step: 1, fractionDigits: 0, unit: .degrees),
            ]),
        module(.zoomBlur, "Zoom Blur", .lens, "arrow.up.left.and.arrow.down.right", "Radial streaks from an adjustable center.", mix: 1, previewMix: 1,
            renderer: { OpticalBlurEffectRenderer(moduleID: .zoomBlur) },
            renderConfiguration: .init(edgeMode: .unfold), parameters: [
                scalar(.amount, "Amount", "rays", 0.22, 0.22, range: 0...0.8), centerParameter(),
            ]),
        module(.kaleidoscope, "Mirror / Kaleidoscope", .distortion, "hexagon", "Fold the image into rotational mirror segments.", mix: 1, previewMix: 1,
            renderer: { SpatialEffectRenderer(moduleID: .kaleidoscope, kind: .kaleidoscope) },
            renderConfiguration: .init(edgeMode: .unfold), parameters: [
                scalar(.segments, "Segments", "hexagon", 6, 6, range: 1...16, step: 1, fractionDigits: 0, unit: .unitless),
                scalar(.angle, "Rotation", "angle", 15, 15, range: -180...180, step: 1, fractionDigits: 0, unit: .degrees), centerParameter(),
            ]),
        module(.duotone, "Duotone", .colorGrade, "circle.lefthalf.filled", "Map shadows and highlights to two editable colors.", mix: 1, previewMix: 1,
            renderer: { DuotoneEffectRenderer() }, parameters: [
                colorParameter(.shadowColor, "Shadows", RGBAColor(red: 0.06, green: 0.08, blue: 0.32, alpha: 1)),
                colorParameter(.highlightColor, "Highlights", RGBAColor(red: 1, green: 0.72, blue: 0.3, alpha: 1)),
                scalar(.contrast, "Contrast", "circle.lefthalf.filled", 0.2, 0.2),
            ]),
        module(.displacementMap, "Displacement Map", .distortion, "map", "An animated two-channel procedural map displaces the image.", mix: 1, previewMix: 1,
            renderer: { SpatialEffectRenderer(moduleID: .displacementMap, kind: .displacementMap) },
            renderConfiguration: .init(edgeMode: .unfold, usesDisplacementMap: true), parameters: [
                scalar(.amount, "Amount", "arrow.up.left.and.arrow.down.right", 0.07, 0.07, range: 0...0.3),
                scalar(.frequency, "Scale", "square.grid.3x3", 5, 5, range: 1...20, step: 0.1),
                scalar(.speed, "Speed", "speedometer", 0.3, 0.3, range: -3...3),
                scalar(.detail, "Detail", "waveform", 0.5, 0.5),
            ]),
        module(.echoTrails, "Echo / Trails", .lens, "square.3.layers.3d", "Blend time-offset source frames into fading trails.", mix: 1, previewMix: 1,
            renderer: { EchoTrailsEffectRenderer() },
            renderConfiguration: .init(usesTemporalFrames: true), parameters: [
                scalar(.samples, "Echoes", "square.3.layers.3d", 4, 4, range: 1...6, step: 1, fractionDigits: 0, unit: .unitless),
                scalar(.spacing, "Delay (s)", "clock", 0.08, 0.08, range: 0.01...0.5, step: 0.01, unit: .unitless),
                scalar(.decay, "Decay", "line.diagonal", 0.65, 0.65, range: 0...0.95),
                scalar(.drift, "Drift", "arrow.right", 0.025, 0.025, range: -0.15...0.15),
            ]),
    ]
}


extension EffectRegistry {
    private static let creativeModules: [EffectModuleDescriptor] = [
        module(
            .lightSweep, "Light Sweep", .lens, "sparkles", "An animated light reflection across the layer.", mix: 1,
            previewMix: 1,
            renderer: { CreativeEffectRenderer(moduleID: .lightSweep, kind: .lightSweep) },
            parameters: [
                scalar("position", "Position", "arrow.left.and.right", 0.5, 0.5, range: -1...2),
                scalar(.angle, "Angle", "angle", 25, 25, range: -180...180, step: 1, fractionDigits: 0, unit: .degrees),
                scalar("width", "Width", "arrow.left.and.right", 0.18, 0.18, range: 0.01...1),
                scalar(.amount, "Brightness", "sun.max", 0.8, 0.8, range: 0...2),
                scalar(.speed, "Speed", "speedometer", 0.25, 0.25, range: -2...2),
                colorParameter("tintColor", "Light Color", .white)
            ]),
        module(
            .ribbedGlass, "Ribbed Glass", .distortion, "line.3.vertical", "Refraction through parallel glass ridges.",
            mix: 1, previewMix: 1,
            renderer: { CreativeEffectRenderer(moduleID: .ribbedGlass, kind: .ribbedGlass) },
            renderConfiguration: .init(edgeMode: .unfold),
            parameters: [
                scalar(.wavelength, "Ridge Width", "arrow.left.and.right", 0.06, 0.06, range: 0.005...0.3),
                scalar(.amount, "Refraction", "water.waves", 0.6, 0.6),
                scalar(.angle, "Angle", "angle", 0, 0, range: -180...180, step: 1, fractionDigits: 0, unit: .degrees),
                scalar(.offset, "Offset", "arrow.left.and.right", 0, 0)
            ]),
        module(
            .dither, "Dither", .colorGrade, "square.grid.3x3", "Ordered retro dithering between two editable colors.",
            mix: 1, previewMix: 1,
            renderer: { CreativeEffectRenderer(moduleID: .dither, kind: .dither) },
            parameters: [
                scalar(.amount, "Pixel Size", "square.grid.3x3", 0.006, 0.006, range: 0.001...0.08),
                scalar(.contrast, "Contrast", "circle.lefthalf.filled", 1, 1, range: 0.25...3),
                colorParameter(.shadowColor, "Shadows", RGBAColor(red: 0.06, green: 0.18, blue: 0.1)),
                colorParameter(.highlightColor, "Highlights", RGBAColor(red: 0.75, green: 0.9, blue: 0.5))
            ]),
        module(
            .halftone, "Halftone", .colorGrade, "circle.grid.3x3", "Luminance-sized ink dots on colored paper.", mix: 1,
            previewMix: 1,
            renderer: { CreativeEffectRenderer(moduleID: .halftone, kind: .halftone) },
            parameters: [
                scalar(.amount, "Dot Spacing", "circle.grid.3x3", 0.018, 0.018, range: 0.003...0.15),
                scalar(.angle, "Angle", "angle", 45, 45, range: -180...180, step: 1, fractionDigits: 0, unit: .degrees),
                scalar(.contrast, "Contrast", "circle.lefthalf.filled", 1, 1, range: 0.25...3),
                colorParameter(.shadowColor, "Ink", .black),
                colorParameter(.highlightColor, "Paper", RGBAColor(red: 1, green: 0.94, blue: 0.8))
            ]),
        module(
            .colorSplash, "Color Splash", .colorGrade, "drop.halffull",
            "Keep a selected hue while desaturating the rest.", mix: 1, previewMix: 1,
            renderer: { CreativeEffectRenderer(moduleID: .colorSplash, kind: .colorSplash) },
            parameters: [
                colorParameter("targetColor", "Keep Color", RGBAColor(red: 1, green: 0, blue: 0)),
                scalar("tolerance", "Hue Range", "scope", 0.09, 0.09, range: 0.005...0.5),
                scalar(.softness, "Softness", "circle.dashed", 0.04, 0.04, range: 0.001...0.25),
                scalar(.saturation, "Background Color", "drop", 0, 0)
            ]),
        module(
            .neonEdges, "Neon Edges", .lens, "bolt", "Glowing colored contours over a darkened image.", mix: 1,
            previewMix: 1,
            renderer: { CreativeEffectRenderer(moduleID: .neonEdges, kind: .neonEdges) },
            parameters: [
                scalar("width", "Line Width", "pencil.tip", 0.002, 0.002, range: 0.0005...0.015),
                scalar(.threshold, "Threshold", "slider.horizontal.3", 0.12, 0.12, range: 0...1),
                scalar(.amount, "Glow", "sparkles", 0.7, 0.7),
                scalar("background", "Original Image", "photo", 0.05, 0.05),
                colorParameter("tintColor", "Neon Color", RGBAColor(red: 0.1, green: 0.8, blue: 1))
            ])
    ]
}
