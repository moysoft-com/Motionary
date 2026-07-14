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
        case .effectIntensity(let effectID):
            let title =
                effectStack.effects.first(where: { $0.id == effectID })?.kind.rawValue
                ?? "Effect"
            return KeyframePropertyMetadata(
                title: "\(title) Intensity",
                systemImage: "wand.and.stars",
                group: .effects,
                range: 0...1,
                step: 0.01,
                fractionDigits: 2
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

    var availableKeyframeTargets: [KeyframeTarget] {
        if let shape {
            return [.shapeWidth, .shapeHeight]
                + (shape.kind.supportsCornerRadius ? [.shapeCornerRadius] : [])
                + [.positionX, .positionY, .scale, .rotation, .opacity]
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
        ].compactMap { $0 } + effectStack.effects.map { .effectIntensity($0.id) }
            + (mediaType == .video ? [.volume] : [])
    }

    func keyframeTargets(in section: KeyframeSection) -> [KeyframeTarget] {
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
            return effectStack.effects.map { .effectIntensity($0.id) }
        case .audio:
            guard mediaType == .audio || mediaType == .video else { return [] }
            return [.volume]
        case .textType, .textStyle:
            return []
        }
    }

    func keyframeTimes(in section: KeyframeSection) -> [Double] {
        Array(
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
        case .effectIntensity:
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
        case .effectIntensity(let effectID):
            effectStack.effects.first(where: { $0.id == effectID })?.intensity
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
        case .effectIntensity(let effectID):
            guard let index = effectStack.effects.firstIndex(where: { $0.id == effectID }) else { return }
            effectStack.effects[index].intensity = property
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
        for target in availableKeyframeTargets where !target.isScaleTarget {
            guard let property = animatableProperty(for: target) else { continue }
            let split = property.split(at: time)
            left.setAnimatableProperty(split.left, for: target)
            right.setAnimatableProperty(split.right, for: target)
        }
        return (left, right)
    }

    mutating func trimAnimationsAtStart(by delta: Double, oldDuration: Double) {
        transform.scale = transform.scale.trimmedStart(by: delta, oldDuration: oldDuration)
        for target in availableKeyframeTargets where !target.isScaleTarget {
            guard let property = animatableProperty(for: target) else { continue }
            setAnimatableProperty(
                property.trimmedStart(by: delta, oldDuration: oldDuration),
                for: target
            )
        }
    }

    mutating func trimAnimationsAtEnd(newDuration: Double, oldDuration: Double) {
        transform.scale = transform.scale.trimmedEnd(
            newDuration: newDuration,
            oldDuration: oldDuration
        )
        for target in availableKeyframeTargets where !target.isScaleTarget {
            guard let property = animatableProperty(for: target) else { continue }
            setAnimatableProperty(
                property.trimmedEnd(newDuration: newDuration, oldDuration: oldDuration),
                for: target
            )
        }
    }

    var allKeyframeTimes: [Double] {
        Array(
            Set(
                availableKeyframeTargets.flatMap {
                    animatableProperty(for: $0)?.keyframes.map(\.time) ?? []
                }
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
