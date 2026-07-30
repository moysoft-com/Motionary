// Versioned, renderer-independent effect values and persisted effect stacks.

import Foundation

struct EffectModuleID: RawRepresentable, Codable, Hashable, Sendable, Identifiable,
    ExpressibleByStringLiteral
{
    let rawValue: String

    var id: String { rawValue }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        rawValue = value
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension EffectModuleID {
    private static let prefix = "com.moysoft.motionary.effect."

    static let sepia = EffectModuleID(prefix + "sepia")
    static let noir = EffectModuleID(prefix + "noir")
    static let chrome = EffectModuleID(prefix + "chrome")
    static let blur = EffectModuleID(prefix + "blur")
    static let vignette = EffectModuleID(prefix + "vignette")
    static let cinematicBloom = EffectModuleID(prefix + "cinematic-bloom")
    static let filmHalation = EffectModuleID(prefix + "film-halation")
    static let prismSplit = EffectModuleID(prefix + "prism-split")
    static let analogGlitch = EffectModuleID(prefix + "analog-glitch")
    static let bleachBypass = EffectModuleID(prefix + "bleach-bypass")
    static let cineTeal = EffectModuleID(prefix + "cine-teal")
    static let kodakPrint = EffectModuleID(prefix + "kodak-print")
    static let portraSoft = EffectModuleID(prefix + "portra-soft")
    static let coolFade = EffectModuleID(prefix + "cool-fade")
    static let matteContrast = EffectModuleID(prefix + "matte-contrast")
    static let cleanSharpen = EffectModuleID(prefix + "clean-sharpen")
    static let fineGrain = EffectModuleID(prefix + "fine-grain")
    static let softGlow = EffectModuleID(prefix + "soft-glow")
    static let anamorphicFlare = EffectModuleID(prefix + "anamorphic-flare")
    static let lightLeak = EffectModuleID(prefix + "light-leak")
    static let chromaticAberration = EffectModuleID(prefix + "chromatic-aberration")
    static let barrelWarp = EffectModuleID(prefix + "barrel-warp")

}

struct EffectParameterID: RawRepresentable, Codable, Hashable, Sendable, Identifiable,
    ExpressibleByStringLiteral
{
    let rawValue: String

    var id: String { rawValue }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        rawValue = value
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension EffectParameterID {
    static let radius: EffectParameterID = "radius"
    static let threshold: EffectParameterID = "threshold"
    static let warmth: EffectParameterID = "warmth"
    static let contrast: EffectParameterID = "contrast"
    static let saturation: EffectParameterID = "saturation"
    static let fade: EffectParameterID = "fade"
    static let grain: EffectParameterID = "grain"
    static let sharpness: EffectParameterID = "sharpness"
    static let spread: EffectParameterID = "spread"
    static let offset: EffectParameterID = "offset"
    static let angle: EffectParameterID = "angle"
    static let softness: EffectParameterID = "softness"
    static let warp: EffectParameterID = "warp"
    static let scanlines: EffectParameterID = "scanlines"
    static let exposure: EffectParameterID = "exposure"
}

enum EffectValueComponent: String, Codable, CaseIterable, Hashable, Sendable {
    case scalar
    case red
    case green
    case blue
    case alpha
    case x
    case y
}

struct EffectPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

/// A JSON-compatible value used to preserve future effect values without knowing their schema.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case boolean(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .boolean(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

enum EffectValue: Codable, Equatable, Sendable {
    case scalar(Double)
    case boolean(Bool)
    case color(RGBAColor)
    case point(EffectPoint)
    case option(String)
    /// Contains the complete, unrecognized encoded value, including its type discriminator.
    case opaque(JSONValue)

    private enum KnownType: String {
        case scalar
        case boolean
        case color
        case point
        case option
    }

    init(from decoder: Decoder) throws {
        let encoded = try JSONValue(from: decoder)
        guard case .object(let object) = encoded,
            case .string(let rawType)? = object["type"],
            let type = KnownType(rawValue: rawType),
            let value = object["value"]
        else {
            self = .opaque(encoded)
            return
        }

        switch (type, value) {
        case (.scalar, .number(let scalar)):
            guard let scalar = Self.double(from: scalar) else {
                self = .opaque(encoded)
                return
            }
            self = .scalar(scalar)
        case (.boolean, .boolean(let boolean)):
            self = .boolean(boolean)
        case (.color, .object(let components)):
            guard case .number(let red)? = components["red"],
                case .number(let green)? = components["green"],
                case .number(let blue)? = components["blue"],
                case .number(let alpha)? = components["alpha"],
                let red = Self.double(from: red),
                let green = Self.double(from: green),
                let blue = Self.double(from: blue),
                let alpha = Self.double(from: alpha),
                [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) })
            else {
                self = .opaque(encoded)
                return
            }
            self = .color(RGBAColor(red: red, green: green, blue: blue, alpha: alpha))
        case (.point, .object(let components)):
            guard case .number(let x)? = components["x"],
                case .number(let y)? = components["y"],
                let x = Self.double(from: x),
                let y = Self.double(from: y)
            else {
                self = .opaque(encoded)
                return
            }
            self = .point(EffectPoint(x: x, y: y))
        case (.option, .string(let option)):
            self = .option(option)
        default:
            self = .opaque(encoded)
        }
    }

    func encode(to encoder: Encoder) throws {
        let encoded: JSONValue
        switch self {
        case .scalar(let value):
            encoded = .object([
                "type": .string("scalar"),
                "value": .number(try Self.decimal(from: value)),
            ])
        case .boolean(let value):
            encoded = .object(["type": .string("boolean"), "value": .boolean(value)])
        case .color(let value):
            encoded = .object([
                "type": .string("color"),
                "value": .object([
                    "red": .number(try Self.decimal(from: value.red)),
                    "green": .number(try Self.decimal(from: value.green)),
                    "blue": .number(try Self.decimal(from: value.blue)),
                    "alpha": .number(try Self.decimal(from: value.alpha)),
                ]),
            ])
        case .point(let value):
            encoded = .object([
                "type": .string("point"),
                "value": .object([
                    "x": .number(try Self.decimal(from: value.x)),
                    "y": .number(try Self.decimal(from: value.y)),
                ]),
            ])
        case .option(let value):
            encoded = .object(["type": .string("option"), "value": .string(value)])
        case .opaque(let value):
            encoded = value
        }
        try encoded.encode(to: encoder)
    }

    private static func double(from decimal: Decimal) -> Double? {
        var decimal = decimal
        let representation = NSDecimalString(
            &decimal,
            Locale(identifier: "en_US_POSIX")
        )
        guard let value = Double(representation), value.isFinite else { return nil }
        return value
    }

    private static func decimal(from value: Double) throws -> Decimal {
        guard value.isFinite,
            let decimal = Decimal(
                string: String(value),
                locale: Locale(identifier: "en_US_POSIX")
            )
        else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Effect values must be finite Decimal-compatible numbers."
                )
            )
        }
        return decimal
    }

    func interpolated(to other: EffectValue, progress: Double) -> EffectValue {
        let amount = min(max(progress, 0), 1)
        switch (self, other) {
        case (.scalar(let left), .scalar(let right)):
            return .scalar(left + (right - left) * amount)
        case (.color(let left), .color(let right)):
            return .color(
                RGBAColor(
                    red: left.red + (right.red - left.red) * amount,
                    green: left.green + (right.green - left.green) * amount,
                    blue: left.blue + (right.blue - left.blue) * amount,
                    alpha: left.alpha + (right.alpha - left.alpha) * amount
                )
            )
        case (.point(let left), .point(let right)):
            return .point(
                EffectPoint(
                    x: left.x + (right.x - left.x) * amount,
                    y: left.y + (right.y - left.y) * amount
                )
            )
        default:
            return amount < 1 ? self : other
        }
    }

    func component(_ component: EffectValueComponent) -> Double? {
        switch (self, component) {
        case (.scalar(let value), .scalar): value
        case (.color(let value), .red): value.red
        case (.color(let value), .green): value.green
        case (.color(let value), .blue): value.blue
        case (.color(let value), .alpha): value.alpha
        case (.point(let value), .x): value.x
        case (.point(let value), .y): value.y
        default: nil
        }
    }

    func replacing(_ component: EffectValueComponent, with newValue: Double) -> EffectValue? {
        switch (self, component) {
        case (.scalar, .scalar):
            .scalar(newValue)
        case (.color(let value), .red):
            .color(RGBAColor(red: newValue, green: value.green, blue: value.blue, alpha: value.alpha))
        case (.color(let value), .green):
            .color(RGBAColor(red: value.red, green: newValue, blue: value.blue, alpha: value.alpha))
        case (.color(let value), .blue):
            .color(RGBAColor(red: value.red, green: value.green, blue: newValue, alpha: value.alpha))
        case (.color(let value), .alpha):
            .color(RGBAColor(red: value.red, green: value.green, blue: value.blue, alpha: newValue))
        case (.point(let value), .x):
            .point(EffectPoint(x: newValue, y: value.y))
        case (.point(let value), .y):
            .point(EffectPoint(x: value.x, y: newValue))
        default:
            nil
        }
    }
}

struct EffectParameterState: Codable, Equatable, Sendable {
    var baseValue: EffectValue
    var keyframes: [Keyframe<EffectValue>]

    init(baseValue: EffectValue, keyframes: [Keyframe<EffectValue>] = []) {
        self.baseValue = baseValue
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    init(scalar property: AnimatableProperty<Double>) {
        baseValue = .scalar(property.baseValue)
        keyframes = property.keyframes.map {
            Keyframe(
                id: $0.id,
                time: $0.time,
                value: .scalar($0.value),
                interpolation: $0.interpolation
            )
        }
    }

    func value(at time: Double) -> EffectValue {
        guard !keyframes.isEmpty, let first = keyframes.first, let last = keyframes.last else {
            return baseValue
        }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }

        var lower = 0
        var upper = keyframes.count - 1
        while lower + 1 < upper {
            let midpoint = (lower + upper) / 2
            if keyframes[midpoint].time <= time {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }
        let left = keyframes[lower]
        let right = keyframes[upper]
        let span = max(right.time - left.time, KeyframeMergeSupport.minimumInterpolationSpan)
        return left.value.interpolated(
            to: right.value,
            progress: left.interpolation.progress(at: (time - left.time) / span)
        )
    }

    func scalarProperty() -> AnimatableProperty<Double>? {
        guard case .scalar(let baseValue) = baseValue else { return nil }
        var frames: [Keyframe<Double>] = []
        for frame in keyframes {
            guard case .scalar(let value) = frame.value else { return nil }
            frames.append(
                Keyframe(
                    id: frame.id,
                    time: frame.time,
                    value: value,
                    interpolation: frame.interpolation
                )
            )
        }
        return AnimatableProperty(baseValue: baseValue, keyframes: frames)
    }

    func property(for component: EffectValueComponent) -> AnimatableProperty<Double>? {
        guard let baseValue = baseValue.component(component) else { return nil }
        var frames: [Keyframe<Double>] = []
        for frame in keyframes {
            guard let value = frame.value.component(component) else { return nil }
            frames.append(
                Keyframe(
                    id: frame.id,
                    time: frame.time,
                    value: value,
                    interpolation: frame.interpolation
                )
            )
        }
        return AnimatableProperty(baseValue: baseValue, keyframes: frames)
    }

    mutating func setScalarProperty(_ property: AnimatableProperty<Double>) {
        self = EffectParameterState(scalar: property)
    }

    mutating func setProperty(
        _ property: AnimatableProperty<Double>,
        for component: EffectValueComponent
    ) {
        guard let replacedBase = baseValue.replacing(component, with: property.baseValue) else { return }
        let original = self
        baseValue = replacedBase
        let times = KeyframeMergeSupport.mergedTimes([
            property.keyframes.map(\.time),
            original.keyframes.map(\.time)
        ])
        keyframes = times.compactMap { time in
            let editedFrame = KeyframeMergeSupport.frame(in: property.keyframes, at: time)
            let existingFrame = KeyframeMergeSupport.frame(in: original.keyframes, at: time)
            guard let value = original.value(at: time).replacing(
                component,
                with: property.value(at: time)
            ) else {
                return nil
            }
            return Keyframe(
                id: editedFrame?.id ?? existingFrame?.id ?? UUID(),
                time: time,
                value: value,
                interpolation: editedFrame?.interpolation ?? existingFrame?.interpolation ?? .linear
            )
        }
    }

    func split(at time: Double) -> (left: EffectParameterState, right: EffectParameterState) {
        guard !keyframes.isEmpty else { return (self, self) }
        let splitTime = max(time, 0)
        let splitValue = value(at: splitTime)
        let tolerance = KeyframeMergeSupport.timeTolerance

        if let exactIndex = keyframes.firstIndex(where: { abs($0.time - splitTime) <= tolerance }) {
            var leftFrames = Array(keyframes[...exactIndex])
            leftFrames[leftFrames.count - 1].time = splitTime
            var rightFrames = Array(keyframes[exactIndex...])
            for index in rightFrames.indices {
                rightFrames[index].time = max(rightFrames[index].time - splitTime, 0)
            }
            return (
                EffectParameterState(baseValue: baseValue, keyframes: leftFrames),
                EffectParameterState(baseValue: splitValue, keyframes: rightFrames)
            )
        }

        var leftFrames = keyframes.filter { $0.time < splitTime }
        var rightFrames = keyframes.filter { $0.time > splitTime }
        leftFrames.append(Keyframe(time: splitTime, value: splitValue))
        rightFrames.insert(Keyframe(time: 0, value: splitValue), at: 0)
        for index in rightFrames.indices.dropFirst() {
            rightFrames[index].time = max(rightFrames[index].time - splitTime, 0)
        }
        return (
            EffectParameterState(baseValue: baseValue, keyframes: leftFrames),
            EffectParameterState(baseValue: splitValue, keyframes: rightFrames)
        )
    }

    func trimmedStart(by delta: Double, oldDuration: Double) -> EffectParameterState {
        guard !keyframes.isEmpty else { return self }
        if delta >= 0 {
            return split(at: min(delta, oldDuration)).right
        }
        let extensionDuration = -delta
        let edgeValue = value(at: 0)
        var frames = keyframes
        for index in frames.indices { frames[index].time += extensionDuration }
        frames.insert(Keyframe(time: 0, value: edgeValue, interpolation: .hold), at: 0)
        return EffectParameterState(baseValue: edgeValue, keyframes: frames)
    }

    func trimmedEnd(newDuration: Double, oldDuration: Double) -> EffectParameterState {
        guard !keyframes.isEmpty else { return self }
        let duration = max(newDuration, 0)
        if duration <= oldDuration {
            return split(at: duration).left
        }
        var frames = keyframes
        let edgeValue = value(at: oldDuration)
        if frames.last?.time ?? 0 < oldDuration - KeyframeMergeSupport.timeTolerance {
            frames.append(Keyframe(time: oldDuration, value: edgeValue, interpolation: .hold))
        } else if let lastIndex = frames.indices.last {
            frames[lastIndex].interpolation = .hold
        }
        frames.append(Keyframe(time: duration, value: edgeValue))
        return EffectParameterState(baseValue: baseValue, keyframes: frames)
    }
}

struct EffectInstance: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var moduleID: EffectModuleID
    var moduleVersion: Int
    var isEnabled: Bool
    var mix: AnimatableProperty<Double>
    var seed: UInt64
    var parameters: [String: EffectParameterState]

    init(
        id: UUID = UUID(),
        moduleID: EffectModuleID,
        moduleVersion: Int = 1,
        isEnabled: Bool = true,
        mix: AnimatableProperty<Double> = AnimatableProperty(baseValue: 1),
        seed: UInt64 = EffectInstance.randomSeed(),
        parameters: [String: EffectParameterState] = [:]
    ) {
        self.id = id
        self.moduleID = moduleID
        self.moduleVersion = max(moduleVersion, 1)
        self.isEnabled = isEnabled
        self.mix = mix
        self.seed = seed
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case moduleID
        case moduleVersion
        case isEnabled
        case mix
        case seed
        case parameters
        case kind
        case intensity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let moduleID = try container.decodeIfPresent(EffectModuleID.self, forKey: .moduleID) {
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            self.moduleID = moduleID
            moduleVersion = max(try container.decodeIfPresent(Int.self, forKey: .moduleVersion) ?? 1, 1)
            isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
            mix = try container.decodeIfPresent(AnimatableProperty<Double>.self, forKey: .mix)
                ?? AnimatableProperty(baseValue: 1)
            seed = try container.decodeIfPresent(UInt64.self, forKey: .seed)
                ?? Self.deterministicSeed(for: id)
            parameters = try container.decodeIfPresent(
                [String: EffectParameterState].self,
                forKey: .parameters
            ) ?? [:]
            self = try EffectRegistry.shared.migrated(self)
            return
        }

        let legacyID = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let legacyKind = try container.decode(String.self, forKey: .kind)
        guard let legacy = LegacyEffectV10Catalog.entry(named: legacyKind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown schema-10 effect kind: \(legacyKind)"
            )
        }
        let legacyParameters = try container.decodeIfPresent(
            [String: AnimatableProperty<Double>].self,
            forKey: .parameters
        ) ?? [:]

        id = legacyID
        moduleID = legacy.moduleID
        moduleVersion = 1
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        mix = try container.decodeIfPresent(AnimatableProperty<Double>.self, forKey: .intensity)
            ?? AnimatableProperty(baseValue: legacy.defaultMix)
        seed = Self.deterministicSeed(for: legacyID)
        parameters = legacy.parameterDefaults.mapValues {
            EffectParameterState(baseValue: .scalar($0))
        }
        for (parameterID, property) in legacyParameters {
            parameters[parameterID] = EffectParameterState(scalar: property)
        }
        self = try EffectRegistry.shared.migrated(self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(moduleID, forKey: .moduleID)
        try container.encode(moduleVersion, forKey: .moduleVersion)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(mix, forKey: .mix)
        try container.encode(seed, forKey: .seed)
        try container.encode(parameters, forKey: .parameters)
    }

    func value(for parameterID: EffectParameterID, at time: Double) -> EffectValue? {
        parameters[parameterID.rawValue]?.value(at: time)
    }

    func resolvedMix(at time: Double) -> Double {
        let value = mix.value(at: time)
        return min(max(value.isFinite ? value : 0, 0), 1)
    }

    func scalarValue(for parameterID: EffectParameterID, at time: Double) -> Double? {
        guard case .scalar(let value)? = value(for: parameterID, at: time) else { return nil }
        return value
    }

    func scalarProperty(for parameterID: EffectParameterID) -> AnimatableProperty<Double>? {
        parameters[parameterID.rawValue]?.scalarProperty()
    }

    func property(
        for parameterID: EffectParameterID,
        component: EffectValueComponent
    ) -> AnimatableProperty<Double>? {
        parameters[parameterID.rawValue]?.property(for: component)
    }

    mutating func setScalarProperty(
        _ property: AnimatableProperty<Double>,
        for parameterID: EffectParameterID
    ) {
        parameters[parameterID.rawValue] = EffectParameterState(scalar: property)
    }

    mutating func setProperty(
        _ property: AnimatableProperty<Double>,
        for parameterID: EffectParameterID,
        component: EffectValueComponent
    ) {
        guard var state = parameters[parameterID.rawValue] else { return }
        state.setProperty(property, for: component)
        parameters[parameterID.rawValue] = state
    }

    static func deterministicSeed(for id: UUID) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var uuid = id.uuid
        withUnsafeBytes(of: &uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
        }
        return hash
    }

    static func randomSeed() -> UInt64 {
        var generator = SystemRandomNumberGenerator()
        return UInt64.random(in: UInt64.min...UInt64.max, using: &generator)
    }
}

struct EffectStack: Codable, Equatable, Sendable {
    var effects: [EffectInstance]

    init(effects: [EffectInstance] = []) {
        self.effects = effects
    }

    var allKeyframeTimes: [Double] {
        Array(
            Set(
                effects.flatMap { effect in
                    effect.mix.keyframes.map(\.time)
                        + effect.parameters.values.flatMap { $0.keyframes.map(\.time) }
                }
            )
        ).sorted()
    }

    func splittingAnimations(at time: Double) -> (left: EffectStack, right: EffectStack) {
        var left = self
        var right = self
        for effectIndex in effects.indices {
            let mix = effects[effectIndex].mix.split(at: time)
            left.effects[effectIndex].mix = mix.left
            right.effects[effectIndex].mix = mix.right
            for parameterID in Array(effects[effectIndex].parameters.keys) {
                guard let parameter = effects[effectIndex].parameters[parameterID] else { continue }
                let split = parameter.split(at: time)
                left.effects[effectIndex].parameters[parameterID] = split.left
                right.effects[effectIndex].parameters[parameterID] = split.right
            }
        }
        return (left, right)
    }

    mutating func trimAnimationsAtStart(by delta: Double, oldDuration: Double) {
        for effectIndex in effects.indices {
            effects[effectIndex].mix = effects[effectIndex].mix.trimmedStart(
                by: delta,
                oldDuration: oldDuration
            )
            for parameterID in Array(effects[effectIndex].parameters.keys) {
                effects[effectIndex].parameters[parameterID] = effects[effectIndex]
                    .parameters[parameterID]?
                    .trimmedStart(by: delta, oldDuration: oldDuration)
            }
        }
    }

    mutating func trimAnimationsAtEnd(newDuration: Double, oldDuration: Double) {
        for effectIndex in effects.indices {
            effects[effectIndex].mix = effects[effectIndex].mix.trimmedEnd(
                newDuration: newDuration,
                oldDuration: oldDuration
            )
            for parameterID in Array(effects[effectIndex].parameters.keys) {
                effects[effectIndex].parameters[parameterID] = effects[effectIndex]
                    .parameters[parameterID]?
                    .trimmedEnd(newDuration: newDuration, oldDuration: oldDuration)
            }
        }
    }
}

private struct LegacyEffectV10Entry {
    let moduleID: EffectModuleID
    let defaultMix: Double
    let parameterDefaults: [String: Double]
}

private enum LegacyEffectV10Catalog {
    static func entry(named name: String) -> LegacyEffectV10Entry? {
        entries[name]
    }

    // This table is intentionally independent from EffectRegistry. Changing new module defaults must
    // never change how an existing schema-10 project migrates.
    private static let entries: [String: LegacyEffectV10Entry] = [
        "Sepia": entry(.sepia, 0.6, [.warmth: 0.68, .contrast: 0.18]),
        "Noir": entry(.noir, 0.6, [.contrast: 0.54, .grain: 0.18]),
        "Chrome": entry(.chrome, 0.6, [.saturation: 0.62, .contrast: 0.34]),
        "Blur": entry(.blur, 0.6, [.radius: 0.44]),
        "Vignette": entry(.vignette, 0.6, [.radius: 0.6, .softness: 0.58]),
        "Cinematic Bloom": entry(
            .cinematicBloom,
            0.55,
            [.radius: 0.56, .threshold: 0.58, .saturation: 0.44]
        ),
        "Film Halation": entry(
            .filmHalation,
            0.52,
            [.radius: 0.48, .warmth: 0.62, .threshold: 0.56]
        ),
        "Prism Split": entry(.prismSplit, 0.5, [.offset: 0.46, .spread: 0.28]),
        "Analog Glitch": entry(.analogGlitch, 0.42, [.offset: 0.42, .scanlines: 0.42]),
        "Bleach Bypass": entry(
            .bleachBypass,
            0.58,
            [.contrast: 0.54, .saturation: 0.68, .sharpness: 0.36]
        ),
        "Cine Teal": entry(
            .cineTeal,
            0.62,
            [.warmth: 0.5, .saturation: 0.48, .contrast: 0.32]
        ),
        "Kodak Print": entry(
            .kodakPrint,
            0.56,
            [.warmth: 0.58, .fade: 0.22, .grain: 0.2]
        ),
        "Portra Soft": entry(
            .portraSoft,
            0.52,
            [.softness: 0.42, .warmth: 0.42, .saturation: 0.32]
        ),
        "Cool Fade": entry(
            .coolFade,
            0.5,
            [.fade: 0.42, .saturation: 0.32, .contrast: 0.18]
        ),
        "Matte Contrast": entry(.matteContrast, 0.58, [.fade: 0.24, .contrast: 0.56]),
        "Clean Sharpen": entry(.cleanSharpen, 0.45, [.sharpness: 0.54, .radius: 0.28]),
        "Fine Grain": entry(.fineGrain, 0.36, [.grain: 0.42, .contrast: 0.34]),
        "Soft Glow": entry(.softGlow, 0.48, [.radius: 0.48, .threshold: 0.44]),
        "Anamorphic Flare": entry(
            .anamorphicFlare,
            0.42,
            [.spread: 0.58, .threshold: 0.7, .warmth: 0.34]
        ),
        "Light Leak": entry(
            .lightLeak,
            0.44,
            [.angle: 26, .warmth: 0.62, .spread: 0.5]
        ),
        "Chromatic Aberration": entry(
            .chromaticAberration,
            0.36,
            [.offset: 0.38, .softness: 0.58]
        ),
        "Barrel Warp": entry(.barrelWarp, 0.34, [.warp: 0.32, .softness: 0.45]),
    ]

    private static func entry(
        _ moduleID: EffectModuleID,
        _ defaultMix: Double,
        _ parameters: [EffectParameterID: Double]
    ) -> LegacyEffectV10Entry {
        LegacyEffectV10Entry(
            moduleID: moduleID,
            defaultMix: defaultMix,
            parameterDefaults: Dictionary(uniqueKeysWithValues: parameters.map { ($0.key.rawValue, $0.value) })
        )
    }
}
