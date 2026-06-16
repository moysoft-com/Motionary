import Foundation

struct ProjectContent: Codable, Equatable {
    var schemaVersion: Int
    var editorProject: EditorProject

    init(editorProject: EditorProject) {
        self.schemaVersion = EditorProject.currentSchemaVersion
        self.editorProject = editorProject
    }

    init(
        clips: [Clip],
        keyframes: [Keyframe<Double>],
        selectedEffect: VideoEffect,
        effectIntensity: Double,
        title: String = "Untitled Project"
    ) {
        self.schemaVersion = EditorProject.currentSchemaVersion
        self.editorProject = EditorProject.migratingLegacy(
            title: title,
            clips: clips,
            keyframes: keyframes,
            selectedEffect: selectedEffect,
            effectIntensity: effectIntensity
        )
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

        if let editorProject = try container.decodeIfPresent(EditorProject.self, forKey: .editorProject) {
            self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? editorProject.schemaVersion
            self.editorProject = editorProject
            return
        }

        let clips = try container.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        let keyframes = try container.decodeIfPresent([Keyframe<Double>].self, forKey: .keyframes) ?? []
        let selectedEffect = try container.decodeIfPresent(VideoEffect.self, forKey: .selectedEffect) ?? .none
        let effectIntensity = try container.decodeIfPresent(Double.self, forKey: .effectIntensity) ?? 0.6

        self.schemaVersion = EditorProject.currentSchemaVersion
        self.editorProject = EditorProject.migratingLegacy(
            title: "Migrated Project",
            clips: clips,
            keyframes: keyframes,
            selectedEffect: selectedEffect,
            effectIntensity: effectIntensity
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(EditorProject.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(editorProject, forKey: .editorProject)
    }
}
