// Editor commands, timeline operation results, and supported canvas presets.

import Foundation

enum KeyframeTarget: Hashable, Identifiable {
    case positionX
    case positionY
    case scale
    case scaleX
    case scaleY
    case rotation
    case opacity
    case brightness
    case contrast
    case saturation
    case exposure
    case effectIntensity(UUID)
    case volume

    var id: String {
        switch self {
        case .positionX: "transform.positionX"
        case .positionY: "transform.positionY"
        case .scale: "transform.scale"
        case .scaleX: "transform.scaleX"
        case .scaleY: "transform.scaleY"
        case .rotation: "transform.rotation"
        case .opacity: "transform.opacity"
        case .brightness: "adjustments.brightness"
        case .contrast: "adjustments.contrast"
        case .saturation: "adjustments.saturation"
        case .exposure: "adjustments.exposure"
        case .effectIntensity(let id): "effect.\(id.uuidString).intensity"
        case .volume: "audio.volume"
        }
    }
}

enum KeyframeSection: String, CaseIterable, Identifiable {
    case transform = "Transform"
    case adjust = "Adjust"
    case effects = "Effects"
    case audio = "Audio"

    var id: String { rawValue }
}

enum KeyframePropertyGroup: String, CaseIterable, Identifiable {
    case transform = "Transform"
    case adjustments = "Adjustments"
    case effects = "Effects"
    case audio = "Audio"

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

    func settings(frameRate: Int32) -> RenderSettings {
        RenderSettings(width: width, height: height, frameRate: frameRate)
    }

    static let presets: [CanvasRatioPreset] = [
        CanvasRatioPreset(id: "9:16", title: "9:16", width: 1080, height: 1920),
        CanvasRatioPreset(id: "1:1", title: "1:1", width: 1080, height: 1080),
        CanvasRatioPreset(id: "16:9", title: "16:9", width: 1920, height: 1080),
        CanvasRatioPreset(id: "4:5", title: "4:5", width: 1080, height: 1350)
    ]
}
