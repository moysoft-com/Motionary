// Visual transform, adjustment, effect, and render-setting value types.

import CoreGraphics
import Foundation
import SwiftUI

struct ScaleValue: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(x: Double = 1, y: Double = 1) {
        self.x = x
        self.y = y
    }
}

struct AnimatableScale: Codable, Equatable, Sendable {
    var baseValue: ScaleValue
    var keyframes: [Keyframe<ScaleValue>]
    var isLinked: Bool

    init(
        baseValue: ScaleValue = ScaleValue(),
        keyframes: [Keyframe<ScaleValue>] = [],
        isLinked: Bool = true
    ) {
        self.baseValue = baseValue
        self.keyframes = keyframes.sorted { $0.time < $1.time }
        self.isLinked = isLinked
    }

    init(legacy property: AnimatableProperty<Double>) {
        baseValue = ScaleValue(x: property.baseValue, y: property.baseValue)
        keyframes = property.keyframes.map {
            Keyframe(
                id: $0.id,
                time: $0.time,
                value: ScaleValue(x: $0.value, y: $0.value),
                interpolation: $0.interpolation
            )
        }
        isLinked = true
    }

    func value(at time: Double) -> ScaleValue {
        guard !keyframes.isEmpty else { return baseValue }
        guard let first = keyframes.first, let last = keyframes.last else { return baseValue }
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
        let progress = left.interpolation.progress(at: (time - left.time) / span)
        return ScaleValue(
            x: left.value.x + (right.value.x - left.value.x) * progress,
            y: left.value.y + (right.value.y - left.value.y) * progress
        )
    }

    func axisProperty(_ axis: ScaleAxis) -> AnimatableProperty<Double> {
        AnimatableProperty(
            baseValue: axis == .x ? baseValue.x : baseValue.y,
            keyframes: keyframes.map {
                Keyframe(
                    id: $0.id,
                    time: $0.time,
                    value: axis == .x ? $0.value.x : $0.value.y,
                    interpolation: $0.interpolation
                )
            }
        )
    }

    mutating func setAxisProperty(
        _ property: AnimatableProperty<Double>,
        axis: ScaleAxis
    ) {
        let previous = self
        let other = previous.axisProperty(axis == .x ? .y : .x)
        if axis == .x {
            baseValue.x = property.baseValue
        } else {
            baseValue.y = property.baseValue
        }

        let times = KeyframeMergeSupport.mergedTimes([
            property.keyframes.map(\.time),
            other.keyframes.map(\.time)
        ])
        keyframes = times.map { time in
            let editedFrame = KeyframeMergeSupport.frame(in: property.keyframes, at: time)
            let otherFrame = KeyframeMergeSupport.frame(in: other.keyframes, at: time)
            return Keyframe(
                id: editedFrame?.id ?? otherFrame?.id ?? UUID(),
                time: time,
                value: axis == .x
                    ? ScaleValue(x: property.value(at: time), y: other.value(at: time))
                    : ScaleValue(x: other.value(at: time), y: property.value(at: time)),
                interpolation: editedFrame?.interpolation ?? otherFrame?.interpolation ?? .linear
            )
        }
    }

    mutating func setKeyframe(
        at time: Double,
        value: ScaleValue,
        tolerance: Double
    ) -> UUID {
        if let index = keyframes.firstIndex(where: { abs($0.time - time) <= tolerance }) {
            let id = keyframes[index].id
            keyframes[index].time = time
            keyframes[index].value = value
            keyframes.sort { $0.time < $1.time }
            return id
        }
        let frame = Keyframe(time: time, value: value)
        keyframes.append(frame)
        keyframes.sort { $0.time < $1.time }
        return frame.id
    }

    mutating func removeKeyframe(at time: Double, tolerance: Double) -> Bool {
        let originalCount = keyframes.count
        keyframes.removeAll { abs($0.time - time) <= tolerance }
        return keyframes.count != originalCount
    }

    mutating func setInterpolation(
        _ interpolation: KeyframeInterpolation,
        keyframeID: UUID
    ) {
        guard let index = keyframes.firstIndex(where: { $0.id == keyframeID }) else { return }
        keyframes[index].interpolation = interpolation
    }

    func split(at time: Double) -> (left: AnimatableScale, right: AnimatableScale) {
        let splitX = axisProperty(.x).split(at: time)
        let splitY = axisProperty(.y).split(at: time)
        return (
            AnimatableScale.merging(
                x: splitX.left,
                y: splitY.left,
                isLinked: isLinked
            ),
            AnimatableScale.merging(
                x: splitX.right,
                y: splitY.right,
                isLinked: isLinked
            )
        )
    }

    func trimmedStart(by delta: Double, oldDuration: Double) -> AnimatableScale {
        AnimatableScale.merging(
            x: axisProperty(.x).trimmedStart(by: delta, oldDuration: oldDuration),
            y: axisProperty(.y).trimmedStart(by: delta, oldDuration: oldDuration),
            isLinked: isLinked
        )
    }

    func trimmedEnd(newDuration: Double, oldDuration: Double) -> AnimatableScale {
        AnimatableScale.merging(
            x: axisProperty(.x).trimmedEnd(newDuration: newDuration, oldDuration: oldDuration),
            y: axisProperty(.y).trimmedEnd(newDuration: newDuration, oldDuration: oldDuration),
            isLinked: isLinked
        )
    }

    private static func merging(
        x: AnimatableProperty<Double>,
        y: AnimatableProperty<Double>,
        isLinked: Bool
    ) -> AnimatableScale {
        let times = KeyframeMergeSupport.mergedTimes([
            x.keyframes.map(\.time),
            y.keyframes.map(\.time)
        ])
        let frames = times.map { time in
            let xFrame = KeyframeMergeSupport.frame(in: x.keyframes, at: time)
            let yFrame = KeyframeMergeSupport.frame(in: y.keyframes, at: time)
            return Keyframe(
                id: xFrame?.id ?? yFrame?.id ?? UUID(),
                time: time,
                value: ScaleValue(x: x.value(at: time), y: y.value(at: time)),
                interpolation: xFrame?.interpolation ?? yFrame?.interpolation ?? .linear
            )
        }
        return AnimatableScale(
            baseValue: ScaleValue(x: x.baseValue, y: y.baseValue),
            keyframes: frames,
            isLinked: isLinked
        )
    }
}

enum ScaleAxis {
    case x
    case y
}

/// Animatable transform values applied during preview and export rendering.
struct ClipTransform: Codable, Equatable, Sendable {
    var positionX: AnimatableProperty<Double>
    var positionY: AnimatableProperty<Double>
    var scale: AnimatableScale
    var rotationDegrees: AnimatableProperty<Double>
    var opacity: AnimatableProperty<Double>
    var isFlippedHorizontally: Bool
    var isFlippedVertically: Bool

    init(
        positionX: AnimatableProperty<Double> = AnimatableProperty(baseValue: 0),
        positionY: AnimatableProperty<Double> = AnimatableProperty(baseValue: 0),
        scale: AnimatableScale = AnimatableScale(),
        rotationDegrees: AnimatableProperty<Double> = AnimatableProperty(baseValue: 0),
        opacity: AnimatableProperty<Double> = AnimatableProperty(baseValue: 1),
        isFlippedHorizontally: Bool = false,
        isFlippedVertically: Bool = false
    ) {
        self.positionX = positionX
        self.positionY = positionY
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.opacity = opacity
        self.isFlippedHorizontally = isFlippedHorizontally
        self.isFlippedVertically = isFlippedVertically
    }

    private enum CodingKeys: String, CodingKey {
        case positionX
        case positionY
        case scale
        case rotationDegrees
        case opacity
        case isFlippedHorizontally
        case isFlippedVertically
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        positionX = try container.decode(AnimatableProperty<Double>.self, forKey: .positionX)
        positionY = try container.decode(AnimatableProperty<Double>.self, forKey: .positionY)
        if let decodedScale = try? container.decode(AnimatableScale.self, forKey: .scale) {
            scale = decodedScale
        } else {
            let legacyScale = try container.decode(AnimatableProperty<Double>.self, forKey: .scale)
            scale = AnimatableScale(legacy: legacyScale)
        }
        rotationDegrees = try container.decode(AnimatableProperty<Double>.self, forKey: .rotationDegrees)
        opacity = try container.decode(AnimatableProperty<Double>.self, forKey: .opacity)
        isFlippedHorizontally =
            try container.decodeIfPresent(Bool.self, forKey: .isFlippedHorizontally) ?? false
        isFlippedVertically =
            try container.decodeIfPresent(Bool.self, forKey: .isFlippedVertically) ?? false
    }
}

extension ClipTransform {
    func resolved(at time: Double) -> ClipTransform {
        ClipTransform(
            positionX: AnimatableProperty(baseValue: positionX.value(at: time)),
            positionY: AnimatableProperty(baseValue: positionY.value(at: time)),
            scale: AnimatableScale(baseValue: scale.value(at: time), isLinked: scale.isLinked),
            rotationDegrees: AnimatableProperty(baseValue: rotationDegrees.value(at: time)),
            opacity: AnimatableProperty(baseValue: opacity.value(at: time)),
            isFlippedHorizontally: isFlippedHorizontally,
            isFlippedVertically: isFlippedVertically
        )
    }
}

/// Animatable color-adjustment values applied before clip effects.
struct AdjustmentSettings: Codable, Equatable, Sendable {
    var brightness: AnimatableProperty<Double>
    var contrast: AnimatableProperty<Double>
    var saturation: AnimatableProperty<Double>
    var exposure: AnimatableProperty<Double>

    init(
        brightness: AnimatableProperty<Double> = AnimatableProperty(baseValue: 0),
        contrast: AnimatableProperty<Double> = AnimatableProperty(baseValue: 1),
        saturation: AnimatableProperty<Double> = AnimatableProperty(baseValue: 1),
        exposure: AnimatableProperty<Double> = AnimatableProperty(baseValue: 0)
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.exposure = exposure
    }
}


struct RGBAColor: Codable, Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let orange = RGBAColor(red: 1, green: 0.48, blue: 0, alpha: 1)

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    init(_ color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        self.init(
            red: Double(resolved.red),
            green: Double(resolved.green),
            blue: Double(resolved.blue),
            alpha: Double(resolved.opacity)
        )
    }

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// Canvas dimensions and output frame rate.
struct RenderSettings: Codable, Equatable {
    var width: Int
    var height: Int
    var frameRate: Int32
    var backgroundColor: RGBAColor

    var size: CGSize { CGSize(width: width, height: height) }

    init(
        width: Int = 1080,
        height: Int = 1920,
        frameRate: Int32 = 30,
        backgroundColor: RGBAColor = .black
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.backgroundColor = backgroundColor
    }

    init(size: CGSize, frameRate: Int32 = 30, backgroundColor: RGBAColor = .black) {
        let safeWidth = max(Int(size.width.rounded()), 1)
        let safeHeight = max(Int(size.height.rounded()), 1)
        self.width = safeWidth
        self.height = safeHeight
        self.frameRate = frameRate
        self.backgroundColor = backgroundColor
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
        case frameRate
        case backgroundColor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        frameRate = try container.decode(Int32.self, forKey: .frameRate)
        backgroundColor =
            try container.decodeIfPresent(RGBAColor.self, forKey: .backgroundColor)
            ?? .black
    }
}
