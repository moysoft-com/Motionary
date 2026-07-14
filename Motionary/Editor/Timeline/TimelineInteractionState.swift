// Value types shared by timeline drag and track-reordering interactions.

import CoreGraphics
import Foundation

struct TimelineClipDragState: Equatable {
    let clipID: UUID
    let sourceTrackIndex: Int
    let startTimelineStart: Double
    let resolvedPlacement: TimelinePlacementResult
    let itemSnapshot: TimelineItem
    let selectedClipIDBeforeDrag: UUID?
    let selectedTrackIDBeforeDrag: UUID?
    let fingerLocationInWindow: CGPoint?
}

struct TimelineTrackDragState: Equatable {
    let trackID: UUID
    let sourceIndex: Int
    let targetIndex: Int
    let translationY: CGFloat
}
