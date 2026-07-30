// Versioned editor-project storage envelope and legacy decoding boundary.

import Foundation

/// Decoder-only representation used by the pre-timeline project envelope.
private enum LegacyVideoEffect: String, Codable {
    case none = "None"
    case sepia = "Sepia"
    case noir = "Noir"
    case chrome = "Chrome"
    case blur = "Blur"
    case vignette = "Vignette"

    var moduleID: EffectModuleID? {
        switch self {
        case .none: nil
        case .sepia: .sepia
        case .noir: .noir
        case .chrome: .chrome
        case .blur: .blur
        case .vignette: .vignette
        }
    }
}

/// Persists the current editor schema while retaining backward-compatible decoding.
struct ProjectContent: Codable, Equatable {
    var schemaVersion: Int
    var editorProject: EditorProject

    init(editorProject: EditorProject) {
        self.schemaVersion = EditorProject.currentSchemaVersion
        var currentProject = editorProject
        currentProject.schemaVersion = EditorProject.currentSchemaVersion
        self.editorProject = currentProject
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case editorProject
        case clips
        case keyframes
        case selectedEffect
        case effectIntensity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let declaredSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        if let declaredSchemaVersion,
            declaredSchemaVersion > EditorProject.currentSchemaVersion
        {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Project schema \(declaredSchemaVersion) is newer than supported schema \(EditorProject.currentSchemaVersion)."
            )
        }

        if let editorProject = try container.decodeIfPresent(EditorProject.self, forKey: .editorProject) {
            var migratedProject = editorProject.removingTemporaryTracks()
            migratedProject.schemaVersion = EditorProject.currentSchemaVersion
            self.schemaVersion = EditorProject.currentSchemaVersion
            self.editorProject = migratedProject
            return
        }

        let clips = try container.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        let keyframes = try container.decodeIfPresent([Keyframe<Double>].self, forKey: .keyframes) ?? []
        let selectedEffect = try container.decodeIfPresent(
            LegacyVideoEffect.self,
            forKey: .selectedEffect
        ) ?? .none
        let effectIntensity = try container.decodeIfPresent(Double.self, forKey: .effectIntensity) ?? 0.6

        self.schemaVersion = EditorProject.currentSchemaVersion
        self.editorProject = EditorProject.migratingLegacy(
            title: "Migrated Project",
            clips: clips,
            keyframes: keyframes,
            selectedEffectModuleID: selectedEffect.moduleID,
            effectIntensity: effectIntensity
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(EditorProject.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(editorProject.removingTemporaryTracks(), forKey: .editorProject)
    }
}

private extension EditorProject {
    func removingTemporaryTracks() -> EditorProject {
        var persistedProject = self
        persistedProject.schemaVersion = EditorProject.currentSchemaVersion
        let fallbackTrack = persistedProject.tracks.first {
            $0.kind == .undefined && $0.items.isEmpty
        }
        persistedProject.tracks.removeAll { track in
            track.kind == .undefined && track.items.isEmpty
        }
        if persistedProject.tracks.isEmpty {
            persistedProject.tracks = [
                fallbackTrack ?? TimelineTrack(name: "Layer", kind: .undefined)
            ]
        }
        return persistedProject
    }
}
