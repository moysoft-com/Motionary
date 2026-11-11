import Foundation

/// In-memory editor clipboard. Values are copied as complete domain objects so
/// keyframes and effect settings travel with their parent object.
@MainActor
enum EditorClipboard {
    static var effect: EffectInstance?
    static var track: TimelineTrack?
    static var graph: KeyframeInterpolation?
}
