// Text-layer adapters for the editor's shared keyframe UI and commands.

import Foundation

extension TextTimelineItem {
    var availableKeyframeTargets: [KeyframeTarget] {
        keyframeTargets(in: .transform)
            + keyframeTargets(in: .textType)
            + keyframeTargets(in: .textStyle)
    }

    func keyframeTargets(
        in section: KeyframeSection,
        includingInactiveEffects: Bool = false
    ) -> [KeyframeTarget] {
        switch section {
        case .transform:
            return [
                .positionX,
                .positionY,
                visuals.transform.scale.isLinked ? .scale : .scaleX,
                visuals.transform.scale.isLinked ? nil : .scaleY,
                .rotation,
            ].compactMap { $0 }
        case .textType:
            return [.textFontSize, .textLetterSpacing, .textLineSpacing]
        case .textStyle:
            var targets: [KeyframeTarget] = ColorComponent.allCases.map(KeyframeTarget.textFill)
                + [.opacity, .textWidthFraction]
            if style.stroke != nil || (includingInactiveEffects && hasStoredStrokeKeyframes) {
                targets += ColorComponent.allCases.map(KeyframeTarget.textStroke)
                targets.append(.textStrokeWidth)
            }
            if style.shadow != nil || (includingInactiveEffects && hasStoredShadowKeyframes) {
                targets += ColorComponent.allCases.map(KeyframeTarget.textShadow)
                targets += [.textShadowOffsetX, .textShadowOffsetY, .textShadowBlur]
            }
            if style.background != nil || (includingInactiveEffects && hasStoredBackgroundKeyframes) {
                targets += ColorComponent.allCases.map(KeyframeTarget.textBackground)
                targets += [.textBackgroundPadding, .textBackgroundCornerRadius]
            }
            return targets
        case .shape, .adjust, .effects, .audio, .speed:
            return []
        }
    }

    func keyframeTimes(in section: KeyframeSection) -> [Double] {
        Array(
            Set(
                keyframeTargets(in: section, includingInactiveEffects: true).flatMap { target in
                    animatableProperty(for: target)?.keyframes.map(\.time) ?? []
                }
            )
        ).sorted()
    }

    var allKeyframeTimes: [Double] {
        Array(
            Set(
                KeyframeSection.allCases.flatMap { keyframeTimes(in: $0) }
            )
        ).sorted()
    }

    func keyframeSection(for target: KeyframeTarget) -> KeyframeSection {
        switch target {
        case .positionX, .positionY, .scale, .scaleX, .scaleY, .rotation:
            .transform
        case .textFontSize, .textLetterSpacing, .textLineSpacing:
            .textType
        case .opacity, .textFill, .textWidthFraction, .textStroke, .textStrokeWidth,
            .textShadow, .textShadowOffsetX, .textShadowOffsetY, .textShadowBlur,
            .textBackground, .textBackgroundPadding, .textBackgroundCornerRadius:
            .textStyle
        case .shapeWidth, .shapeHeight, .shapeCornerRadius, .brightness, .contrast,
            .saturation, .exposure, .effectIntensity, .volume:
            .transform
        }
    }

    func isKeyframeTargetEnabled(_ target: KeyframeTarget) -> Bool {
        switch target {
        case .textStroke, .textStrokeWidth:
            style.stroke != nil
        case .textShadow, .textShadowOffsetX, .textShadowOffsetY, .textShadowBlur:
            style.shadow != nil
        case .textBackground, .textBackgroundPadding, .textBackgroundCornerRadius:
            style.background != nil
        default:
            animatableProperty(for: target) != nil
        }
    }

    func animatableProperty(for target: KeyframeTarget) -> AnimatableProperty<Double>? {
        switch target {
        case .positionX: visuals.transform.positionX
        case .positionY: visuals.transform.positionY
        case .scale, .scaleX: visuals.transform.scale.axisProperty(.x)
        case .scaleY: visuals.transform.scale.axisProperty(.y)
        case .rotation: visuals.transform.rotationDegrees
        case .opacity: visuals.transform.opacity
        case .textFontSize: propertyAnimations.fontSize.withBaseValue(style.fontSize)
        case .textLetterSpacing: propertyAnimations.letterSpacing.withBaseValue(style.letterSpacing)
        case .textLineSpacing: propertyAnimations.lineSpacing.withBaseValue(style.lineSpacing)
        case .textFill(let component):
            propertyAnimations.fillColor.withBaseValue(style.color).componentProperty(component)
        case .textWidthFraction:
            propertyAnimations.widthFraction.withBaseValue(layout.widthFraction)
        case .textStroke(let component):
            propertyAnimations.strokeColor
                .withBaseValue(style.stroke?.color ?? propertyAnimations.strokeColor.baseValue)
                .componentProperty(component)
        case .textStrokeWidth:
            propertyAnimations.strokeWidth.withBaseValue(
                style.stroke?.width ?? propertyAnimations.strokeWidth.baseValue
            )
        case .textShadow(let component):
            propertyAnimations.shadowColor
                .withBaseValue(style.shadow?.color ?? propertyAnimations.shadowColor.baseValue)
                .componentProperty(component)
        case .textShadowOffsetX:
            propertyAnimations.shadowOffsetX.withBaseValue(
                style.shadow?.offsetX ?? propertyAnimations.shadowOffsetX.baseValue
            )
        case .textShadowOffsetY:
            propertyAnimations.shadowOffsetY.withBaseValue(
                style.shadow?.offsetY ?? propertyAnimations.shadowOffsetY.baseValue
            )
        case .textShadowBlur:
            propertyAnimations.shadowBlur.withBaseValue(
                style.shadow?.blur ?? propertyAnimations.shadowBlur.baseValue
            )
        case .textBackground(let component):
            propertyAnimations.backgroundColor
                .withBaseValue(style.background?.color ?? propertyAnimations.backgroundColor.baseValue)
                .componentProperty(component)
        case .textBackgroundPadding:
            propertyAnimations.backgroundPadding.withBaseValue(
                style.background?.padding ?? propertyAnimations.backgroundPadding.baseValue
            )
        case .textBackgroundCornerRadius:
            propertyAnimations.backgroundCornerRadius.withBaseValue(
                style.background?.cornerRadius ?? propertyAnimations.backgroundCornerRadius.baseValue
            )
        case .shapeWidth, .shapeHeight, .shapeCornerRadius, .brightness, .contrast,
            .saturation, .exposure, .effectIntensity, .volume:
            nil
        }
    }

    mutating func setAnimatableProperty(
        _ property: AnimatableProperty<Double>,
        for target: KeyframeTarget
    ) {
        switch target {
        case .positionX:
            visuals.transform.positionX = property
        case .positionY:
            visuals.transform.positionY = property
        case .scale, .scaleX:
            visuals.transform.scale.setAxisProperty(property, axis: .x)
        case .scaleY:
            visuals.transform.scale.setAxisProperty(property, axis: .y)
        case .rotation:
            visuals.transform.rotationDegrees = property
        case .opacity:
            visuals.transform.opacity = property
        case .textFontSize:
            propertyAnimations.fontSize = property
            if property.keyframes.isEmpty { style.fontSize = property.baseValue }
        case .textLetterSpacing:
            propertyAnimations.letterSpacing = property
            if property.keyframes.isEmpty { style.letterSpacing = property.baseValue }
        case .textLineSpacing:
            propertyAnimations.lineSpacing = property
            if property.keyframes.isEmpty { style.lineSpacing = property.baseValue }
        case .textFill(let component):
            propertyAnimations.fillColor.setComponentProperty(property, component: component)
            if propertyAnimations.fillColor.keyframes.isEmpty {
                style.color = propertyAnimations.fillColor.baseValue
            }
        case .textWidthFraction:
            propertyAnimations.widthFraction = property
            if property.keyframes.isEmpty { layout.widthFraction = property.baseValue }
        case .textStroke(let component):
            propertyAnimations.strokeColor.setComponentProperty(property, component: component)
            if propertyAnimations.strokeColor.keyframes.isEmpty, style.stroke != nil {
                style.stroke?.color = propertyAnimations.strokeColor.baseValue
            }
        case .textStrokeWidth:
            propertyAnimations.strokeWidth = property
            if property.keyframes.isEmpty, style.stroke != nil {
                style.stroke?.width = property.baseValue
            }
        case .textShadow(let component):
            propertyAnimations.shadowColor.setComponentProperty(property, component: component)
            if propertyAnimations.shadowColor.keyframes.isEmpty, style.shadow != nil {
                style.shadow?.color = propertyAnimations.shadowColor.baseValue
            }
        case .textShadowOffsetX:
            propertyAnimations.shadowOffsetX = property
            if property.keyframes.isEmpty, style.shadow != nil { style.shadow?.offsetX = property.baseValue }
        case .textShadowOffsetY:
            propertyAnimations.shadowOffsetY = property
            if property.keyframes.isEmpty, style.shadow != nil { style.shadow?.offsetY = property.baseValue }
        case .textShadowBlur:
            propertyAnimations.shadowBlur = property
            if property.keyframes.isEmpty, style.shadow != nil { style.shadow?.blur = property.baseValue }
        case .textBackground(let component):
            propertyAnimations.backgroundColor.setComponentProperty(property, component: component)
            if propertyAnimations.backgroundColor.keyframes.isEmpty, style.background != nil {
                style.background?.color = propertyAnimations.backgroundColor.baseValue
            }
        case .textBackgroundPadding:
            propertyAnimations.backgroundPadding = property
            if property.keyframes.isEmpty, style.background != nil {
                style.background?.padding = property.baseValue
            }
        case .textBackgroundCornerRadius:
            propertyAnimations.backgroundCornerRadius = property
            if property.keyframes.isEmpty, style.background != nil {
                style.background?.cornerRadius = property.baseValue
            }
        case .shapeWidth, .shapeHeight, .shapeCornerRadius, .brightness, .contrast,
            .saturation, .exposure, .effectIntensity, .volume:
            break
        }
    }

    func value(for target: KeyframeTarget, at time: Double) -> Double? {
        if target.isScaleTarget {
            let scale = visuals.transform.scale.value(at: time)
            return target == .scaleY ? scale.y : scale.x
        }
        return animatableProperty(for: target)?.value(at: time)
    }

    func color(for property: TextColorProperty, at time: Double) -> RGBAColor? {
        switch property {
        case .fill:
            return propertyAnimations.fillColor.keyframes.isEmpty
                ? style.color
                : propertyAnimations.fillColor.value(at: time)
        case .stroke:
            guard let stroke = style.stroke else { return nil }
            return propertyAnimations.strokeColor.keyframes.isEmpty
                ? stroke.color
                : propertyAnimations.strokeColor.value(at: time)
        case .shadow:
            guard let shadow = style.shadow else { return nil }
            return propertyAnimations.shadowColor.keyframes.isEmpty
                ? shadow.color
                : propertyAnimations.shadowColor.value(at: time)
        case .background:
            guard let background = style.background else { return nil }
            return propertyAnimations.backgroundColor.keyframes.isEmpty
                ? background.color
                : propertyAnimations.backgroundColor.value(at: time)
        }
    }

    mutating func setColorAnimation(_ animation: AnimatableColor, for property: TextColorProperty) {
        switch property {
        case .fill:
            propertyAnimations.fillColor = animation
            if animation.keyframes.isEmpty { style.color = animation.baseValue }
        case .stroke:
            propertyAnimations.strokeColor = animation
            if animation.keyframes.isEmpty, style.stroke != nil { style.stroke?.color = animation.baseValue }
        case .shadow:
            propertyAnimations.shadowColor = animation
            if animation.keyframes.isEmpty, style.shadow != nil { style.shadow?.color = animation.baseValue }
        case .background:
            propertyAnimations.backgroundColor = animation
            if animation.keyframes.isEmpty, style.background != nil { style.background?.color = animation.baseValue }
        }
    }

    func colorAnimation(for property: TextColorProperty) -> AnimatableColor {
        switch property {
        case .fill: propertyAnimations.fillColor.withBaseValue(style.color)
        case .stroke:
            propertyAnimations.strokeColor.withBaseValue(
                style.stroke?.color ?? propertyAnimations.strokeColor.baseValue
            )
        case .shadow:
            propertyAnimations.shadowColor.withBaseValue(
                style.shadow?.color ?? propertyAnimations.shadowColor.baseValue
            )
        case .background:
            propertyAnimations.backgroundColor.withBaseValue(
                style.background?.color ?? propertyAnimations.backgroundColor.baseValue
            )
        }
    }

    /// Resolves typography and appearance into static values for one local time.
    /// Rendering and live preview should both use this method.
    func resolved(at time: Double) -> TextTimelineItem {
        var result = self
        result.style.fontSize = resolved(propertyAnimations.fontSize, fallback: style.fontSize, at: time)
        result.style.letterSpacing = resolved(
            propertyAnimations.letterSpacing,
            fallback: style.letterSpacing,
            at: time
        )
        result.style.lineSpacing = resolved(
            propertyAnimations.lineSpacing,
            fallback: style.lineSpacing,
            at: time
        )
        result.style.color = color(for: .fill, at: time) ?? style.color
        result.layout.widthFraction = resolved(
            propertyAnimations.widthFraction,
            fallback: layout.widthFraction,
            at: time
        )

        if var stroke = style.stroke {
            stroke.color = color(for: .stroke, at: time) ?? stroke.color
            stroke.width = resolved(propertyAnimations.strokeWidth, fallback: stroke.width, at: time)
            result.style.stroke = stroke
        }
        if var shadow = style.shadow {
            shadow.color = color(for: .shadow, at: time) ?? shadow.color
            shadow.offsetX = resolved(propertyAnimations.shadowOffsetX, fallback: shadow.offsetX, at: time)
            shadow.offsetY = resolved(propertyAnimations.shadowOffsetY, fallback: shadow.offsetY, at: time)
            shadow.blur = resolved(propertyAnimations.shadowBlur, fallback: shadow.blur, at: time)
            result.style.shadow = shadow
        }
        if var background = style.background {
            background.color = color(for: .background, at: time) ?? background.color
            background.padding = resolved(
                propertyAnimations.backgroundPadding,
                fallback: background.padding,
                at: time
            )
            background.cornerRadius = resolved(
                propertyAnimations.backgroundCornerRadius,
                fallback: background.cornerRadius,
                at: time
            )
            result.style.background = background
        }
        return result
    }

    mutating func synchronizePropertyAnimationBaseValues() {
        propertyAnimations.fontSize.baseValue = style.fontSize
        propertyAnimations.letterSpacing.baseValue = style.letterSpacing
        propertyAnimations.lineSpacing.baseValue = style.lineSpacing
        propertyAnimations.fillColor.baseValue = style.color
        propertyAnimations.widthFraction.baseValue = layout.widthFraction
        if let stroke = style.stroke {
            propertyAnimations.strokeColor.baseValue = stroke.color
            propertyAnimations.strokeWidth.baseValue = stroke.width
        }
        if let shadow = style.shadow {
            propertyAnimations.shadowColor.baseValue = shadow.color
            propertyAnimations.shadowOffsetX.baseValue = shadow.offsetX
            propertyAnimations.shadowOffsetY.baseValue = shadow.offsetY
            propertyAnimations.shadowBlur.baseValue = shadow.blur
        }
        if let background = style.background {
            propertyAnimations.backgroundColor.baseValue = background.color
            propertyAnimations.backgroundPadding.baseValue = background.padding
            propertyAnimations.backgroundCornerRadius.baseValue = background.cornerRadius
        }
    }

    func keyframeMetadata(for target: KeyframeTarget) -> KeyframePropertyMetadata {
        switch target {
        case .positionX:
            textMetadata("Position X", "arrow.left.and.right", .transform, -2...2, 0.01, 2)
        case .positionY:
            textMetadata("Position Y", "arrow.up.and.down", .transform, -2...2, 0.01, 2)
        case .scale:
            textMetadata("Scale", "arrow.up.left.and.arrow.down.right", .transform, 0.01...100, 0.01, 2)
        case .scaleX:
            textMetadata("Scale X", "arrow.left.and.right", .transform, 0.01...100, 0.01, 2)
        case .scaleY:
            textMetadata("Scale Y", "arrow.up.and.down", .transform, 0.01...100, 0.01, 2)
        case .rotation:
            textMetadata("Rotation", "rotate.right", .transform, -720...720, 1, 0)
        case .opacity:
            textMetadata("Opacity", "circle.lefthalf.filled", .textStyle, 0...1, 0.01, 2)
        case .textFontSize:
            textMetadata("Size", "textformat.size", .textType, 8...512, 1, 0)
        case .textLetterSpacing:
            textMetadata("Tracking", "character.cursor.ibeam", .textType, -20...80, 0.5, 1)
        case .textLineSpacing:
            textMetadata("Line Spacing", "line.3.horizontal", .textType, -30...200, 1, 0)
        case .textFill(let component):
            colorMetadata("Fill", component)
        case .textWidthFraction:
            textMetadata("Text Box", "rectangle.horizontal", .textStyle, 0.1...1, 0.01, 2)
        case .textStroke(let component):
            colorMetadata("Outline", component)
        case .textStrokeWidth:
            textMetadata("Outline Width", "scribble.variable", .textStyle, 0...40, 0.5, 1)
        case .textShadow(let component):
            colorMetadata("Shadow", component)
        case .textShadowOffsetX:
            textMetadata("Shadow X", "arrow.left.and.right", .textStyle, -100...100, 1, 0)
        case .textShadowOffsetY:
            textMetadata("Shadow Y", "arrow.up.and.down", .textStyle, -100...100, 1, 0)
        case .textShadowBlur:
            textMetadata("Shadow Blur", "drop.halffull", .textStyle, 0...100, 1, 0)
        case .textBackground(let component):
            colorMetadata("Background", component)
        case .textBackgroundPadding:
            textMetadata("Background Padding", "arrow.left.and.right", .textStyle, 0...120, 1, 0)
        case .textBackgroundCornerRadius:
            textMetadata("Background Corners", "rectangle.roundedtop", .textStyle, 0...120, 1, 0)
        case .shapeWidth, .shapeHeight, .shapeCornerRadius, .brightness, .contrast,
            .saturation, .exposure, .effectIntensity, .volume:
            textMetadata("Property", "slider.horizontal.3", .textStyle, -1...1, 0.01, 2)
        }
    }

    private var hasStoredStrokeKeyframes: Bool {
        !propertyAnimations.strokeColor.keyframes.isEmpty
            || !propertyAnimations.strokeWidth.keyframes.isEmpty
    }

    private var hasStoredShadowKeyframes: Bool {
        !propertyAnimations.shadowColor.keyframes.isEmpty
            || !propertyAnimations.shadowOffsetX.keyframes.isEmpty
            || !propertyAnimations.shadowOffsetY.keyframes.isEmpty
            || !propertyAnimations.shadowBlur.keyframes.isEmpty
    }

    private var hasStoredBackgroundKeyframes: Bool {
        !propertyAnimations.backgroundColor.keyframes.isEmpty
            || !propertyAnimations.backgroundPadding.keyframes.isEmpty
            || !propertyAnimations.backgroundCornerRadius.keyframes.isEmpty
    }

    private func resolved(
        _ property: AnimatableProperty<Double>,
        fallback: Double,
        at time: Double
    ) -> Double {
        property.keyframes.isEmpty ? fallback : property.value(at: time)
    }

    private func textMetadata(
        _ title: String,
        _ systemImage: String,
        _ group: KeyframePropertyGroup,
        _ range: ClosedRange<Double>,
        _ step: Double,
        _ fractionDigits: Int
    ) -> KeyframePropertyMetadata {
        KeyframePropertyMetadata(
            title: title,
            systemImage: systemImage,
            group: group,
            range: range,
            step: step,
            fractionDigits: fractionDigits
        )
    }

    private func colorMetadata(
        _ title: String,
        _ component: ColorComponent
    ) -> KeyframePropertyMetadata {
        textMetadata(
            "\(title) \(component.rawValue.capitalized)",
            "paintpalette",
            .textStyle,
            0...1,
            0.01,
            2
        )
    }
}

extension TimelineItem {
    func keyframeTargets(in section: KeyframeSection) -> [KeyframeTarget] {
        switch self {
        case .media, .shape:
            legacyClip()?.keyframeTargets(in: section) ?? []
        case .text(let item):
            item.keyframeTargets(in: section)
        case .caption, .adjustment, .compound:
            []
        }
    }

    func keyframeTimes(in section: KeyframeSection) -> [Double] {
        switch self {
        case .media where section == .speed:
            return []
        case .media, .shape:
            return visibleKeyframeTimes(legacyClip()?.keyframeTimes(in: section) ?? [])
        case .text(let item):
            return item.keyframeTimes(in: section)
        case .caption, .adjustment, .compound:
            return []
        }
    }

    var allKeyframeTimes: [Double] {
        switch self {
        case .media:
            return visibleKeyframeTimes(legacyClip()?.allKeyframeTimes ?? [])
        case .shape:
            return visibleKeyframeTimes(legacyClip()?.allKeyframeTimes ?? [])
        case .text(let item):
            return item.allKeyframeTimes
        case .adjustment(let item):
            return visibleKeyframeTimes(visualKeyframeTimes(item.visuals))
        case .compound(let item):
            return visibleKeyframeTimes(visualKeyframeTimes(item.visuals))
        case .caption:
            return []
        }
    }

    private func visibleKeyframeTimes(_ times: [Double]) -> [Double] {
        times.filter {
            $0 >= -0.000_001 && $0 <= placementDuration + 0.000_001
        }
    }

    private func visualKeyframeTimes(_ visuals: TimelineItemVisuals) -> [Double] {
        let properties = [
            visuals.transform.positionX,
            visuals.transform.positionY,
            visuals.transform.rotationDegrees,
            visuals.transform.opacity,
            visuals.adjustments.brightness,
            visuals.adjustments.contrast,
            visuals.adjustments.saturation,
            visuals.adjustments.exposure,
            visuals.volume,
        ]
        let times = properties.flatMap { $0.keyframes.map(\.time) }
            + visuals.transform.scale.keyframes.map(\.time)
            + visuals.effectStack.effects.flatMap { $0.intensity.keyframes.map(\.time) }
        return Array(Set(times)).sorted()
    }
}

private extension AnimatableProperty where Value == Double {
    func withBaseValue(_ value: Double) -> AnimatableProperty<Double> {
        var result = self
        result.baseValue = value
        return result
    }
}

private extension AnimatableColor {
    func withBaseValue(_ value: RGBAColor) -> AnimatableColor {
        var result = self
        result.baseValue = value
        return result
    }
}
