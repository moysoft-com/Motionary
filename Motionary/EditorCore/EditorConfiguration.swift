// Editor commands, timeline operation results, and supported canvas presets.

import Foundation

struct EditorUnitSpace {
    static let referenceUnits = 1_000.0

    let pixelSize: CGSize

    init(size: CGSize) {
        pixelSize = CGSize(
            width: max(abs(size.width), 1),
            height: max(abs(size.height), 1)
        )
    }

    var unitsPerPixel: Double {
        Self.referenceUnits / Double(max(pixelSize.width, pixelSize.height))
    }

    var pixelsPerUnit: Double { 1 / unitsPerPixel }
    var width: Double { Double(pixelSize.width) * unitsPerPixel }
    var height: Double { Double(pixelSize.height) * unitsPerPixel }

    func units(fromPixels pixels: Double) -> Double {
        pixels * unitsPerPixel
    }

    func pixels(fromUnits units: Double) -> Double {
        units * pixelsPerUnit
    }

    func horizontalUnits(fromNormalizedPosition value: Double) -> Double {
        value * width * 0.5
    }

    func verticalUnits(fromNormalizedPosition value: Double) -> Double {
        value * height * 0.5
    }

    func normalizedHorizontalPosition(fromUnits value: Double) -> Double {
        value / max(width * 0.5, 0.000_001)
    }

    func normalizedVerticalPosition(fromUnits value: Double) -> Double {
        value / max(height * 0.5, 0.000_001)
    }
}

enum KeyframeTarget: Hashable, Identifiable {
    case positionX
    case positionY
    case scale
    case scaleX
    case scaleY
    case rotation
    case opacity
    case shapeWidth
    case shapeHeight
    case shapeCornerRadius
    case brightness
    case contrast
    case saturation
    case exposure
    case effectMix(UUID)
    case effectParameter(UUID, EffectParameterID, EffectValueComponent)
    case volume
    case textFontSize
    case textLetterSpacing
    case textLineSpacing
    case textFill(ColorComponent)
    case textWidthFraction
    case textStroke(ColorComponent)
    case textStrokeWidth
    case textShadow(ColorComponent)
    case textShadowOffsetX
    case textShadowOffsetY
    case textShadowBlur
    case textBackground(ColorComponent)
    case textBackgroundPadding
    case textBackgroundCornerRadius

    var id: String {
        switch self {
        case .positionX: "transform.positionX"
        case .positionY: "transform.positionY"
        case .scale: "transform.scale"
        case .scaleX: "transform.scaleX"
        case .scaleY: "transform.scaleY"
        case .rotation: "transform.rotation"
        case .opacity: "transform.opacity"
        case .shapeWidth: "shape.width"
        case .shapeHeight: "shape.height"
        case .shapeCornerRadius: "shape.cornerRadius"
        case .brightness: "adjustments.brightness"
        case .contrast: "adjustments.contrast"
        case .saturation: "adjustments.saturation"
        case .exposure: "adjustments.exposure"
        case .effectMix(let id): "effect.\(id.uuidString).mix"
        case .effectParameter(let id, let parameterID, let component):
            "effect.\(id.uuidString).\(parameterID.rawValue).\(component.rawValue)"
        case .volume: "audio.volume"
        case .textFontSize: "text.type.fontSize"
        case .textLetterSpacing: "text.type.letterSpacing"
        case .textLineSpacing: "text.type.lineSpacing"
        case .textFill(let component): "text.style.fill.\(component.rawValue)"
        case .textWidthFraction: "text.style.widthFraction"
        case .textStroke(let component): "text.style.stroke.\(component.rawValue)"
        case .textStrokeWidth: "text.style.stroke.width"
        case .textShadow(let component): "text.style.shadow.\(component.rawValue)"
        case .textShadowOffsetX: "text.style.shadow.offsetX"
        case .textShadowOffsetY: "text.style.shadow.offsetY"
        case .textShadowBlur: "text.style.shadow.blur"
        case .textBackground(let component): "text.style.background.\(component.rawValue)"
        case .textBackgroundPadding: "text.style.background.padding"
        case .textBackgroundCornerRadius: "text.style.background.cornerRadius"
        }
    }
}

enum KeyframeSection: String, CaseIterable, Identifiable {
    case shape = "Shape"
    case transform = "Transform"
    case adjust = "Adjust"
    case effects = "Effects"
    case audio = "Audio"
    case speed = "Speed"
    case textType = "Type"
    case textStyle = "Style"

    var id: String { rawValue }
}

enum KeyframePropertyGroup: String, CaseIterable, Identifiable {
    case shape = "Shape"
    case transform = "Transform"
    case adjustments = "Adjustments"
    case effects = "Effects"
    case audio = "Audio"
    case textType = "Type"
    case textStyle = "Style"

    var id: String { rawValue }
}

struct KeyframePropertyMetadata {
    let title: String
    let systemImage: String
    let group: KeyframePropertyGroup
    let range: ClosedRange<Double>
    let step: Double
    let fractionDigits: Int

    func formattedValue(_ value: Double) -> String {
        switch group {
        case .shape:
            return "\(Int(value.rounded())) px"
        case .audio:
            return "\(Int((value * 100).rounded()))%"
        default:
            return value.formatted(
                .number.precision(.fractionLength(fractionDigits))
            )
        }
    }
}

struct KeyframeSegment: Equatable {
    let clipID: UUID
    let section: KeyframeSection
    var effectID: UUID? = nil
    let startTime: Double
    let endTime: Double
    let interpolation: KeyframeInterpolation
}

struct TimelinePlacementResult: Equatable {
    var start: Double
    var trackIndex: Int
    var snapped: Bool
    var snapTime: Double?
}

struct TimelineTrimResult {
    var edgeTime: Double
    var appliedDelta: Double
    var snapped: Bool
}

struct CanvasRatioPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let width: Int
    let height: Int

    func settings(frameRate: Int32, backgroundColor: RGBAColor = .black) -> RenderSettings {
        RenderSettings(
            width: width,
            height: height,
            frameRate: frameRate,
            backgroundColor: backgroundColor
        )
    }

    static let presets: [CanvasRatioPreset] = [
        CanvasRatioPreset(id: "9:16", title: "9:16", width: 1080, height: 1920),
        CanvasRatioPreset(id: "1:1", title: "1:1", width: 1080, height: 1080),
        CanvasRatioPreset(id: "16:9", title: "16:9", width: 1920, height: 1080),
        CanvasRatioPreset(id: "4:5", title: "4:5", width: 1080, height: 1350)
    ]
}
