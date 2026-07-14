// Persisted, interpolated typography and appearance properties for text layers.

import Foundation

enum ColorComponent: String, CaseIterable, Codable, Hashable, Sendable {
    case red
    case green
    case blue
    case alpha
}

enum TextColorProperty: String, CaseIterable, Codable, Hashable, Sendable {
    case fill
    case stroke
    case shadow
    case background
}

/// A color value with synchronized RGBA keyframes.
struct AnimatableColor: Codable, Equatable, Sendable {
    var baseValue: RGBAColor
    var keyframes: [Keyframe<RGBAColor>]

    init(baseValue: RGBAColor, keyframes: [Keyframe<RGBAColor>] = []) {
        self.baseValue = baseValue
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    func value(at time: Double) -> RGBAColor {
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
        let span = max(right.time - left.time, 0.000_001)
        let progress = left.interpolation.progress(at: (time - left.time) / span)
        return left.value.interpolated(to: right.value, progress: progress)
    }

    func componentProperty(_ component: ColorComponent) -> AnimatableProperty<Double> {
        AnimatableProperty(
            baseValue: baseValue.value(for: component),
            keyframes: keyframes.map { frame in
                Keyframe(
                    id: frame.id,
                    time: frame.time,
                    value: frame.value.value(for: component),
                    interpolation: frame.interpolation
                )
            }
        )
    }

    mutating func setComponentProperty(
        _ property: AnimatableProperty<Double>,
        component: ColorComponent
    ) {
        let previous = self
        baseValue.setValue(property.baseValue, for: component)
        keyframes = property.keyframes.map { frame in
            var color = previous.value(at: frame.time)
            color.setValue(frame.value, for: component)
            return Keyframe(
                id: frame.id,
                time: frame.time,
                value: color,
                interpolation: frame.interpolation
            )
        }
    }

    @discardableResult
    mutating func setKeyframe(
        at time: Double,
        value: RGBAColor,
        tolerance: Double
    ) -> UUID {
        if let index = keyframes.firstIndex(where: { abs($0.time - time) <= tolerance }) {
            let id = keyframes[index].id
            keyframes[index].time = max(time, 0)
            keyframes[index].value = value
            keyframes.sort { $0.time < $1.time }
            return id
        }

        let frame = Keyframe(time: time, value: value)
        keyframes.append(frame)
        keyframes.sort { $0.time < $1.time }
        return frame.id
    }

    @discardableResult
    mutating func removeKeyframe(at time: Double, tolerance: Double) -> Bool {
        let originalCount = keyframes.count
        keyframes.removeAll { abs($0.time - time) <= tolerance }
        return originalCount != keyframes.count
    }

    func split(at time: Double) -> (left: AnimatableColor, right: AnimatableColor) {
        let red = componentProperty(.red).split(at: time)
        let green = componentProperty(.green).split(at: time)
        let blue = componentProperty(.blue).split(at: time)
        let alpha = componentProperty(.alpha).split(at: time)
        return (
            Self.merging(red: red.left, green: green.left, blue: blue.left, alpha: alpha.left),
            Self.merging(red: red.right, green: green.right, blue: blue.right, alpha: alpha.right)
        )
    }

    func trimmedStart(by delta: Double, oldDuration: Double) -> AnimatableColor {
        Self.merging(
            red: componentProperty(.red).trimmedStart(by: delta, oldDuration: oldDuration),
            green: componentProperty(.green).trimmedStart(by: delta, oldDuration: oldDuration),
            blue: componentProperty(.blue).trimmedStart(by: delta, oldDuration: oldDuration),
            alpha: componentProperty(.alpha).trimmedStart(by: delta, oldDuration: oldDuration)
        )
    }

    func trimmedEnd(newDuration: Double, oldDuration: Double) -> AnimatableColor {
        Self.merging(
            red: componentProperty(.red).trimmedEnd(newDuration: newDuration, oldDuration: oldDuration),
            green: componentProperty(.green).trimmedEnd(newDuration: newDuration, oldDuration: oldDuration),
            blue: componentProperty(.blue).trimmedEnd(newDuration: newDuration, oldDuration: oldDuration),
            alpha: componentProperty(.alpha).trimmedEnd(newDuration: newDuration, oldDuration: oldDuration)
        )
    }

    private static func merging(
        red: AnimatableProperty<Double>,
        green: AnimatableProperty<Double>,
        blue: AnimatableProperty<Double>,
        alpha: AnimatableProperty<Double>
    ) -> AnimatableColor {
        AnimatableColor(
            baseValue: RGBAColor(
                red: red.baseValue,
                green: green.baseValue,
                blue: blue.baseValue,
                alpha: alpha.baseValue
            ),
            keyframes: red.keyframes.map { frame in
                Keyframe(
                    id: frame.id,
                    time: frame.time,
                    value: RGBAColor(
                        red: frame.value,
                        green: green.value(at: frame.time),
                        blue: blue.value(at: frame.time),
                        alpha: alpha.value(at: frame.time)
                    ),
                    interpolation: frame.interpolation
                )
            }
        )
    }
}

/// All smoothly animatable text properties. Discrete font, alignment, and
/// effect-enabled state intentionally remain on `TextStyle`.
struct TextPropertyAnimations: Codable, Equatable, Sendable {
    var fontSize: AnimatableProperty<Double>
    var letterSpacing: AnimatableProperty<Double>
    var lineSpacing: AnimatableProperty<Double>

    var fillColor: AnimatableColor
    var widthFraction: AnimatableProperty<Double>
    var strokeColor: AnimatableColor
    var strokeWidth: AnimatableProperty<Double>
    var shadowColor: AnimatableColor
    var shadowOffsetX: AnimatableProperty<Double>
    var shadowOffsetY: AnimatableProperty<Double>
    var shadowBlur: AnimatableProperty<Double>
    var backgroundColor: AnimatableColor
    var backgroundPadding: AnimatableProperty<Double>
    var backgroundCornerRadius: AnimatableProperty<Double>

    init(style: TextStyle = TextStyle(), layout: TextLayout = TextLayout()) {
        let stroke = style.stroke ?? TextStrokeStyle()
        let shadow = style.shadow ?? TextShadowStyle()
        let background = style.background ?? TextBackgroundStyle()
        fontSize = AnimatableProperty(baseValue: style.fontSize)
        letterSpacing = AnimatableProperty(baseValue: style.letterSpacing)
        lineSpacing = AnimatableProperty(baseValue: style.lineSpacing)
        fillColor = AnimatableColor(baseValue: style.color)
        widthFraction = AnimatableProperty(baseValue: layout.widthFraction)
        strokeColor = AnimatableColor(baseValue: stroke.color)
        strokeWidth = AnimatableProperty(baseValue: stroke.width)
        shadowColor = AnimatableColor(baseValue: shadow.color)
        shadowOffsetX = AnimatableProperty(baseValue: shadow.offsetX)
        shadowOffsetY = AnimatableProperty(baseValue: shadow.offsetY)
        shadowBlur = AnimatableProperty(baseValue: shadow.blur)
        backgroundColor = AnimatableColor(baseValue: background.color)
        backgroundPadding = AnimatableProperty(baseValue: background.padding)
        backgroundCornerRadius = AnimatableProperty(baseValue: background.cornerRadius)
    }

    func splitting(at time: Double) -> (left: TextPropertyAnimations, right: TextPropertyAnimations) {
        var left = self
        var right = self
        (left.fontSize, right.fontSize) = fontSize.split(at: time)
        (left.letterSpacing, right.letterSpacing) = letterSpacing.split(at: time)
        (left.lineSpacing, right.lineSpacing) = lineSpacing.split(at: time)
        (left.fillColor, right.fillColor) = fillColor.split(at: time)
        (left.widthFraction, right.widthFraction) = widthFraction.split(at: time)
        (left.strokeColor, right.strokeColor) = strokeColor.split(at: time)
        (left.strokeWidth, right.strokeWidth) = strokeWidth.split(at: time)
        (left.shadowColor, right.shadowColor) = shadowColor.split(at: time)
        (left.shadowOffsetX, right.shadowOffsetX) = shadowOffsetX.split(at: time)
        (left.shadowOffsetY, right.shadowOffsetY) = shadowOffsetY.split(at: time)
        (left.shadowBlur, right.shadowBlur) = shadowBlur.split(at: time)
        (left.backgroundColor, right.backgroundColor) = backgroundColor.split(at: time)
        (left.backgroundPadding, right.backgroundPadding) = backgroundPadding.split(at: time)
        (left.backgroundCornerRadius, right.backgroundCornerRadius) = backgroundCornerRadius.split(at: time)
        return (left, right)
    }

    func trimmingStart(by delta: Double, oldDuration: Double) -> TextPropertyAnimations {
        var result = self
        result.fontSize = fontSize.trimmedStart(by: delta, oldDuration: oldDuration)
        result.letterSpacing = letterSpacing.trimmedStart(by: delta, oldDuration: oldDuration)
        result.lineSpacing = lineSpacing.trimmedStart(by: delta, oldDuration: oldDuration)
        result.fillColor = fillColor.trimmedStart(by: delta, oldDuration: oldDuration)
        result.widthFraction = widthFraction.trimmedStart(by: delta, oldDuration: oldDuration)
        result.strokeColor = strokeColor.trimmedStart(by: delta, oldDuration: oldDuration)
        result.strokeWidth = strokeWidth.trimmedStart(by: delta, oldDuration: oldDuration)
        result.shadowColor = shadowColor.trimmedStart(by: delta, oldDuration: oldDuration)
        result.shadowOffsetX = shadowOffsetX.trimmedStart(by: delta, oldDuration: oldDuration)
        result.shadowOffsetY = shadowOffsetY.trimmedStart(by: delta, oldDuration: oldDuration)
        result.shadowBlur = shadowBlur.trimmedStart(by: delta, oldDuration: oldDuration)
        result.backgroundColor = backgroundColor.trimmedStart(by: delta, oldDuration: oldDuration)
        result.backgroundPadding = backgroundPadding.trimmedStart(by: delta, oldDuration: oldDuration)
        result.backgroundCornerRadius = backgroundCornerRadius.trimmedStart(by: delta, oldDuration: oldDuration)
        return result
    }

    func trimmingEnd(newDuration: Double, oldDuration: Double) -> TextPropertyAnimations {
        var result = self
        result.fontSize = fontSize.trimmedEnd(newDuration: newDuration, oldDuration: oldDuration)
        result.letterSpacing = letterSpacing.trimmedEnd(newDuration: newDuration, oldDuration: oldDuration)
        result.lineSpacing = lineSpacing.trimmedEnd(newDuration: newDuration, oldDuration: oldDuration)
        result.fillColor = fillColor.trimmedEnd(newDuration: newDuration, oldDuration: oldDuration)
        result.widthFraction = widthFraction.trimmedEnd(newDuration: newDuration, oldDuration: oldDuration)
        result.strokeColor = strokeColor.trimmedEnd(newDuration: newDuration, oldDuration: oldDuration)
        result.strokeWidth = strokeWidth.trimmedEnd(newDuration: newDuration, oldDuration: oldDuration)
        result.shadowColor = shadowColor.trimmedEnd(newDuration: newDuration, oldDuration: oldDuration)
        result.shadowOffsetX = shadowOffsetX.trimmedEnd(newDuration: newDuration, oldDuration: oldDuration)
        result.shadowOffsetY = shadowOffsetY.trimmedEnd(newDuration: newDuration, oldDuration: oldDuration)
        result.shadowBlur = shadowBlur.trimmedEnd(newDuration: newDuration, oldDuration: oldDuration)
        result.backgroundColor = backgroundColor.trimmedEnd(newDuration: newDuration, oldDuration: oldDuration)
        result.backgroundPadding = backgroundPadding.trimmedEnd(newDuration: newDuration, oldDuration: oldDuration)
        result.backgroundCornerRadius = backgroundCornerRadius.trimmedEnd(newDuration: newDuration, oldDuration: oldDuration)
        return result
    }
}

private extension RGBAColor {
    func value(for component: ColorComponent) -> Double {
        switch component {
        case .red: red
        case .green: green
        case .blue: blue
        case .alpha: alpha
        }
    }

    mutating func setValue(_ value: Double, for component: ColorComponent) {
        let value = min(max(value, 0), 1)
        switch component {
        case .red: red = value
        case .green: green = value
        case .blue: blue = value
        case .alpha: alpha = value
        }
    }

    func interpolated(to other: RGBAColor, progress: Double) -> RGBAColor {
        RGBAColor(
            red: red + (other.red - red) * progress,
            green: green + (other.green - green) * progress,
            blue: blue + (other.blue - blue) * progress,
            alpha: alpha + (other.alpha - alpha) * progress
        )
    }
}
