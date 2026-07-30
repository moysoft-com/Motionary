// Model conveniences used by editor commands and timeline placement.

import SwiftUI

extension CGSizeValue {
    var displaySafeSize: CGSize {
        CGSize(width: max(abs(width), 1), height: max(abs(height), 1))
    }
}

extension TimelineClip {
    var requiredTrackKind: TrackKind {
        if shape != nil { return .shape }
        return mediaType == .audio ? .audio : .visual
    }

    func keyframeMetadata(for target: KeyframeTarget) -> KeyframePropertyMetadata {
        switch target {
        case .positionX:
            return KeyframePropertyMetadata(
                title: "Position X",
                systemImage: "arrow.left.and.right",
                group: .transform,
                range: -2...2,
                step: 0.01,
                fractionDigits: 2
            )
        case .positionY:
            return KeyframePropertyMetadata(
                title: "Position Y",
                systemImage: "arrow.up.and.down",
                group: .transform,
                range: -2...2,
                step: 0.01,
                fractionDigits: 2
            )
        case .scale:
            return KeyframePropertyMetadata(
                title: "Scale",
                systemImage: "arrow.up.left.and.arrow.down.right",
                group: .transform,
                range: 0.01...100,
                step: 0.01,
                fractionDigits: 2
            )
        case .scaleX:
            return KeyframePropertyMetadata(
                title: "Scale X",
                systemImage: "arrow.left.and.right",
                group: .transform,
                range: 0.01...100,
                step: 0.01,
                fractionDigits: 2
            )
        case .scaleY:
            return KeyframePropertyMetadata(
                title: "Scale Y",
                systemImage: "arrow.up.and.down",
                group: .transform,
                range: 0.01...100,
                step: 0.01,
                fractionDigits: 2
            )
        case .rotation:
            return KeyframePropertyMetadata(
                title: "Rotation",
                systemImage: "rotate.right",
                group: .transform,
                range: -720...720,
                step: 1,
                fractionDigits: 0
            )
        case .opacity:
            return KeyframePropertyMetadata(
                title: "Opacity",
                systemImage: "circle.lefthalf.filled",
                group: .transform,
                range: 0...1,
                step: 0.01,
                fractionDigits: 2
            )
        case .shapeWidth:
            return KeyframePropertyMetadata(
                title: "X Size",
                systemImage: "arrow.left.and.right",
                group: .shape,
                range: 1...8192,
                step: 1,
                fractionDigits: 0
            )
        case .shapeHeight:
            return KeyframePropertyMetadata(
                title: "Y Size",
                systemImage: "arrow.up.and.down",
                group: .shape,
                range: 1...8192,
                step: 1,
                fractionDigits: 0
            )
        case .shapeCornerRadius:
            return KeyframePropertyMetadata(
                title: "Corner Radius",
                systemImage: "rectangle.roundedtop",
                group: .shape,
                range: 0...4096,
                step: 1,
                fractionDigits: 0
            )
        case .brightness:
            return KeyframePropertyMetadata(
                title: "Brightness",
                systemImage: "sun.max",
                group: .adjustments,
                range: -1...1,
                step: 0.01,
                fractionDigits: 2
            )
        case .contrast:
            return KeyframePropertyMetadata(
                title: "Contrast",
                systemImage: "circle.lefthalf.filled",
                group: .adjustments,
                range: 0...4,
                step: 0.01,
                fractionDigits: 2
            )
        case .saturation:
            return KeyframePropertyMetadata(
                title: "Saturation",
                systemImage: "drop.halffull",
                group: .adjustments,
                range: 0...4,
                step: 0.01,
                fractionDigits: 2
            )
        case .exposure:
            return KeyframePropertyMetadata(
                title: "Exposure",
                systemImage: "plusminus.circle",
                group: .adjustments,
                range: -4...4,
                step: 0.01,
                fractionDigits: 2
            )
        case .effectMix:
            return KeyframePropertyMetadata(
                title: "Amount",
                systemImage: "dial.medium",
                group: .effects,
                range: 0...1,
                step: 0.01,
                fractionDigits: 2
            )
        case .effectParameter(let effectID, let parameterID, let component):
            return effectParameterMetadata(
                effectID: effectID,
                parameterID: parameterID,
                component: component
            )
        case .volume:
            return KeyframePropertyMetadata(
                title: "Volume",
                systemImage: "speaker.wave.2",
                group: .audio,
                range: 0...2,
                step: 0.01,
                fractionDigits: 2
            )
        case .textFontSize, .textLetterSpacing, .textLineSpacing, .textFill,
            .textWidthFraction, .textStroke, .textStrokeWidth, .textShadow,
            .textShadowOffsetX, .textShadowOffsetY, .textShadowBlur,
            .textBackground, .textBackgroundPadding, .textBackgroundCornerRadius:
            return KeyframePropertyMetadata(
                title: "Text",
                systemImage: "textformat",
                group: .textStyle,
                range: -1...1,
                step: 0.01,
                fractionDigits: 2
            )
        }
    }

    private func effectParameterMetadata(
        effectID: UUID,
        parameterID: EffectParameterID,
        component: EffectValueComponent
    ) -> KeyframePropertyMetadata {
        guard let effect = effectStack.effects.first(where: { $0.id == effectID }),
            let descriptor = EffectRegistry.shared.descriptor(for: effect.moduleID)?
                .descriptor(for: parameterID)
        else {
            return KeyframePropertyMetadata(
                title: "Effect",
                systemImage: "wand.and.stars",
                group: .effects,
                range: 0...1,
                step: 0.01,
                fractionDigits: 2
            )
        }

        return KeyframePropertyMetadata(
            title: descriptor.componentTitle(component),
            systemImage: descriptor.systemImage,
            group: .effects,
            range: descriptor.scalarRange ?? component.defaultRange,
            step: descriptor.step,
            fractionDigits: descriptor.fractionDigits
        )
    }

    var availableKeyframeTargets: [KeyframeTarget] {
        if let shape {
            return [.shapeWidth, .shapeHeight]
                + (shape.kind.supportsCornerRadius ? [.shapeCornerRadius] : [])
                + [.positionX, .positionY, .scale, .rotation, .opacity]
                + effectStack.effects.flatMap(\.parameterTargets)
        }
        if mediaType == .audio {
            return [.volume]
        }
        return [
            .positionX,
            .positionY,
            transform.scale.isLinked ? .scale : .scaleX,
            transform.scale.isLinked ? nil : .scaleY,
            .rotation,
            .opacity,
            .brightness,
            .contrast,
            .saturation,
            .exposure
        ].compactMap { $0 } + effectStack.effects.flatMap(\.parameterTargets)
            + (mediaType == .video ? [.volume] : [])
    }

    func keyframeTargets(in section: KeyframeSection) -> [KeyframeTarget] {
        keyframeTargets(in: section, effectID: nil)
    }

    func keyframeTargets(in section: KeyframeSection, effectID: UUID?) -> [KeyframeTarget] {
        switch section {
        case .shape:
            guard let shape else { return [] }
            return [.shapeWidth, .shapeHeight]
                + (shape.kind.supportsCornerRadius ? [.shapeCornerRadius] : [])
        case .transform:
            guard mediaType != .audio else { return [] }
            return [
                .positionX,
                .positionY,
                transform.scale.isLinked ? .scale : .scaleX,
                transform.scale.isLinked ? nil : .scaleY,
                .rotation,
            ].compactMap { $0 }
        case .adjust:
            guard mediaType != .audio else { return [] }
            return [.opacity, .brightness, .contrast, .saturation, .exposure]
        case .effects:
            guard mediaType != .audio else { return [] }
            if let effectID {
                return effectStack.effects.first(where: { $0.id == effectID })?.parameterTargets ?? []
            }
            return effectStack.effects.flatMap(\.parameterTargets)
        case .audio:
            guard mediaType == .audio || mediaType == .video else { return [] }
            return [.volume]
        case .speed, .textType, .textStyle:
            return []
        }
    }

    func keyframeTimes(in section: KeyframeSection) -> [Double] {
        keyframeTimes(in: section, effectID: nil)
    }

    func keyframeTimes(in section: KeyframeSection, effectID: UUID?) -> [Double] {
        if section == .effects {
            if let effectID,
                let effect = effectStack.effects.first(where: { $0.id == effectID })
            {
                return KeyframeMergeSupport.mergedTimes([
                    effect.mix.keyframes.map(\.time),
                    effect.parameters.values.flatMap { $0.keyframes.map(\.time) },
                ])
            }
            return effectStack.allKeyframeTimes
        }
        return Array(
            Set(
                keyframeTargets(in: section).flatMap {
                    animatableProperty(for: $0)?.keyframes.map(\.time) ?? []
                }
            )
        )
        .sorted()
    }

    func keyframeSection(for target: KeyframeTarget) -> KeyframeSection {
        switch target {
        case .shapeWidth, .shapeHeight, .shapeCornerRadius:
            .shape
        case .positionX, .positionY, .scale, .scaleX, .scaleY, .rotation:
            .transform
        case .opacity, .brightness, .contrast, .saturation, .exposure:
            .adjust
        case .effectMix, .effectParameter:
            .effects
        case .volume:
            .audio
        case .textFontSize, .textLetterSpacing, .textLineSpacing:
            .textType
        case .textFill, .textWidthFraction, .textStroke, .textStrokeWidth,
            .textShadow, .textShadowOffsetX, .textShadowOffsetY, .textShadowBlur,
            .textBackground, .textBackgroundPadding, .textBackgroundCornerRadius:
            .textStyle
        }
    }

    func animatableProperty(for target: KeyframeTarget) -> AnimatableProperty<Double>? {
        switch target {
        case .shapeWidth: shape?.width
        case .shapeHeight: shape?.height
        case .shapeCornerRadius: shape?.cornerRadius
        case .positionX: transform.positionX
        case .positionY: transform.positionY
        case .scale, .scaleX: transform.scale.axisProperty(.x)
        case .scaleY: transform.scale.axisProperty(.y)
        case .rotation: transform.rotationDegrees
        case .opacity: transform.opacity
        case .brightness: adjustments.brightness
        case .contrast: adjustments.contrast
        case .saturation: adjustments.saturation
        case .exposure: adjustments.exposure
        case .effectMix(let effectID):
            effectStack.effects.first(where: { $0.id == effectID })?.mix
        case .effectParameter(let effectID, let parameterID, let component):
            effectStack.effects.first(where: { $0.id == effectID })?
                .property(for: parameterID, component: component)
        case .volume: volume
        case .textFontSize, .textLetterSpacing, .textLineSpacing, .textFill,
            .textWidthFraction, .textStroke, .textStrokeWidth, .textShadow,
            .textShadowOffsetX, .textShadowOffsetY, .textShadowBlur,
            .textBackground, .textBackgroundPadding, .textBackgroundCornerRadius:
            nil
        }
    }

    mutating func setAnimatableProperty(
        _ property: AnimatableProperty<Double>,
        for target: KeyframeTarget
    ) {
        switch target {
        case .shapeWidth:
            shape?.width = property
        case .shapeHeight:
            shape?.height = property
        case .shapeCornerRadius:
            shape?.cornerRadius = property
        case .positionX:
            transform.positionX = property
        case .positionY:
            transform.positionY = property
        case .scale, .scaleX:
            transform.scale.setAxisProperty(property, axis: .x)
        case .scaleY:
            transform.scale.setAxisProperty(property, axis: .y)
        case .rotation:
            transform.rotationDegrees = property
        case .opacity:
            transform.opacity = property
        case .brightness:
            adjustments.brightness = property
        case .contrast:
            adjustments.contrast = property
        case .saturation:
            adjustments.saturation = property
        case .exposure:
            adjustments.exposure = property
        case .effectMix(let effectID):
            guard let index = effectStack.effects.firstIndex(where: { $0.id == effectID }) else { return }
            effectStack.effects[index].mix = property
        case .effectParameter(let effectID, let parameterID, let component):
            guard let index = effectStack.effects.firstIndex(where: { $0.id == effectID }) else { return }
            effectStack.effects[index].setProperty(
                property,
                for: parameterID,
                component: component
            )
        case .volume:
            volume = property
        case .textFontSize, .textLetterSpacing, .textLineSpacing, .textFill,
            .textWidthFraction, .textStroke, .textStrokeWidth, .textShadow,
            .textShadowOffsetX, .textShadowOffsetY, .textShadowBlur,
            .textBackground, .textBackgroundPadding, .textBackgroundCornerRadius:
            break
        }
    }

    func splittingAnimations(at time: Double) -> (left: TimelineClip, right: TimelineClip) {
        var left = self
        var right = self
        let splitScale = transform.scale.split(at: time)
        left.transform.scale = splitScale.left
        right.transform.scale = splitScale.right
        for target in availableKeyframeTargets where !target.isScaleTarget && target.effectID == nil {
            guard let property = animatableProperty(for: target) else { continue }
            let split = property.split(at: time)
            left.setAnimatableProperty(split.left, for: target)
            right.setAnimatableProperty(split.right, for: target)
        }
        let splitEffects = effectStack.splittingAnimations(at: time)
        left.effectStack = splitEffects.left
        right.effectStack = splitEffects.right
        return (left, right)
    }

    mutating func trimAnimationsAtStart(by delta: Double, oldDuration: Double) {
        transform.scale = transform.scale.trimmedStart(by: delta, oldDuration: oldDuration)
        for target in availableKeyframeTargets where !target.isScaleTarget && target.effectID == nil {
            guard let property = animatableProperty(for: target) else { continue }
            setAnimatableProperty(
                property.trimmedStart(by: delta, oldDuration: oldDuration),
                for: target
            )
        }
        effectStack.trimAnimationsAtStart(by: delta, oldDuration: oldDuration)
    }

    mutating func trimAnimationsAtEnd(newDuration: Double, oldDuration: Double) {
        transform.scale = transform.scale.trimmedEnd(
            newDuration: newDuration,
            oldDuration: oldDuration
        )
        for target in availableKeyframeTargets where !target.isScaleTarget && target.effectID == nil {
            guard let property = animatableProperty(for: target) else { continue }
            setAnimatableProperty(
                property.trimmedEnd(newDuration: newDuration, oldDuration: oldDuration),
                for: target
            )
        }
        effectStack.trimAnimationsAtEnd(newDuration: newDuration, oldDuration: oldDuration)
    }

    var allKeyframeTimes: [Double] {
        Array(
            Set(
                availableKeyframeTargets.filter { $0.effectID == nil }.flatMap {
                    animatableProperty(for: $0)?.keyframes.map(\.time) ?? []
                } + effectStack.allKeyframeTimes
            )
        )
        .sorted()
    }
}

extension KeyframeTarget {
    var isScaleTarget: Bool {
        switch self {
        case .scale, .scaleX, .scaleY:
            true
        default:
            false
        }
    }

    var effectID: UUID? {
        switch self {
        case .effectMix(let id), .effectParameter(let id, _, _):
            id
        default:
            nil
        }
    }
}

extension EffectInstance {
    var parameterTargets: [KeyframeTarget] {
        guard EffectRegistry.shared.availability(of: self) == .available,
            let module = EffectRegistry.shared.descriptor(for: moduleID)
        else {
            return []
        }
        return [.effectMix(id)] + module.parameters.flatMap { descriptor -> [KeyframeTarget] in
            guard descriptor.isAnimatable else { return [] }
            return descriptor.editableComponents.map {
                .effectParameter(id, descriptor.id, $0)
            }
        }
    }
}

private extension EffectParameterDescriptor {
    var editableComponents: [EffectValueComponent] {
        switch valueType {
        case .scalar: [.scalar]
        case .color: [.red, .green, .blue, .alpha]
        case .point: [.x, .y]
        case .boolean, .option: []
        }
    }

    func componentTitle(_ component: EffectValueComponent) -> String {
        switch component {
        case .scalar: title
        case .red, .green, .blue, .alpha, .x, .y:
            "\(title) \(component.rawValue.capitalized)"
        }
    }
}

private extension EffectValueComponent {
    var defaultRange: ClosedRange<Double> {
        switch self {
        case .red, .green, .blue, .alpha:
            0...1
        case .scalar, .x, .y:
            -1...1
        }
    }
}

extension TimelineTrack {
    func canAcceptClipKind(_ requiredKind: TrackKind) -> Bool {
        kind == requiredKind || kind == .undefined
    }
}

extension AnimatableProperty where Value == Double {
    mutating func insertKeyframe(at time: Double) {
        let frame = Keyframe(time: time, value: value(at: time))
        if let index = keyframes.firstIndex(where: { abs($0.time - time) < 0.04 }) {
            keyframes[index] = frame
        } else {
            keyframes.append(frame)
        }
        keyframes.sort { $0.time < $1.time }
    }

}
