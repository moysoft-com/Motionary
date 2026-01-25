import Foundation

struct ProjectContent: Codable, Equatable {
    var clips: [Clip]
    var keyframes: [Keyframe]
    var selectedEffect: VideoEffect
    var effectIntensity: Double
}
