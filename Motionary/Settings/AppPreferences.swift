// Persistent, app-wide preferences shared by settings and feature entry points.

import SwiftUI

enum AppPreferences {
    static let appearanceKey = "appearance"
    static let newProjectFrameRateKey = "newProjectFrameRate"
    static let exportQualityKey = "exportQuality"
    static let exportCodecKey = "exportCodec"
    static let exportContainerKey = "exportContainer"

    static let defaultAppearance = AppAppearance.system.rawValue
    static let defaultFrameRate = 30
    static let defaultExportQuality = ExportQuality.balanced.rawValue
    static let defaultExportCodec = ExportVideoCodec.h264.rawValue
    static let defaultExportContainer = ExportContainer.mp4.rawValue

    static func reset() {
        let defaults = UserDefaults.standard
        [
            appearanceKey,
            newProjectFrameRateKey,
            exportQualityKey,
            exportCodecKey,
            exportContainerKey
        ].forEach(defaults.removeObject(forKey:))
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum ExportQuality: String, CaseIterable, Identifiable {
    case compact
    case balanced
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Compact"
        case .balanced: "Balanced"
        case .high: "High"
        }
    }

    var bitrateMultiplier: Double {
        switch self {
        case .compact: 0.6
        case .balanced: 1
        case .high: 1.5
        }
    }
}

