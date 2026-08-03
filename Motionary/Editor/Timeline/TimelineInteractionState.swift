// Value types shared by timeline drag and track-reordering interactions.

import CoreGraphics
import Foundation
import os
import SwiftUI

struct TimelineViewportWindow: Equatable, Sendable {
    var timeRange: ClosedRange<Double>
    var trackRange: Range<Int>

    static let initial = TimelineViewportWindow(
        timeRange: 0...30,
        trackRange: 0..<12
    )

    func contains(timeRange other: ClosedRange<Double>) -> Bool {
        timeRange.lowerBound <= other.lowerBound
            && timeRange.upperBound >= other.upperBound
    }
}

struct TimelineVirtualizationConfiguration: Equatable, Sendable {
    let centerPadding: CGFloat
    let trackOriginY: CGFloat
    let rowStride: CGFloat
    let trackCount: Int
    let duration: Double
}

enum TimelineScrollSynchronizationPolicy {
    static func shouldSynchronizeOnLayout(
        isPlaying: Bool,
        isUserInteracting: Bool
    ) -> Bool {
        !isPlaying && !isUserInteracting
    }
}

@MainActor
final class TimelineViewportState: ObservableObject {
    @Published private(set) var window: TimelineViewportWindow = .initial

    @discardableResult
    func update(
        contentOffset: CGPoint,
        viewportSize: CGSize,
        pixelsPerSecond: CGFloat,
        configuration: TimelineVirtualizationConfiguration,
        force: Bool = false
    ) -> Bool {
        let safePixelsPerSecond = max(pixelsPerSecond, 1)
        let timelineDuration = max(configuration.duration, 0)
        let visibleDuration = max(Double(viewportSize.width / safePixelsPerSecond), 0.25)
        let visibleStart = max(
            Double((contentOffset.x - configuration.centerPadding) / safePixelsPerSecond),
            0
        )
        let visibleEnd = min(
            max(
                Double(
                    (contentOffset.x + viewportSize.width - configuration.centerPadding)
                        / safePixelsPerSecond
                ),
                visibleStart
            ),
            max(timelineDuration, visibleStart)
        )
        let retentionMargin = visibleDuration * 0.22
        let retainedUpper = min(
            visibleEnd + retentionMargin,
            max(timelineDuration, visibleEnd)
        )
        let retainedVisibleRange: ClosedRange<Double> = ClosedRange(
            uncheckedBounds: (
                lower: min(max(visibleStart - retentionMargin, 0), retainedUpper),
                upper: retainedUpper
            )
        )

        let safeStride = max(configuration.rowStride, 1)
        let firstVisibleTrack = max(
            Int(
                floor(
                    (contentOffset.y - configuration.trackOriginY)
                        / safeStride
                )
            ),
            0
        )
        let lastVisibleTrack = min(
            Int(
                ceil(
                    (contentOffset.y + viewportSize.height - configuration.trackOriginY)
                        / safeStride
                )
            ),
            configuration.trackCount
        )
        let retainedTrackRange: Range<Int> =
            max(firstVisibleTrack - 1, 0)
            ..< min(max(lastVisibleTrack + 1, 0), configuration.trackCount)

        if !force,
            window.contains(timeRange: retainedVisibleRange),
            window.trackRange.lowerBound <= retainedTrackRange.lowerBound,
            window.trackRange.upperBound >= retainedTrackRange.upperBound
        {
            return false
        }

        let horizontalOverscan = visibleDuration * 0.9
        let requestedUpper = min(
            visibleEnd + horizontalOverscan,
            max(timelineDuration, visibleEnd)
        )
        let requestedRange: ClosedRange<Double> = ClosedRange(
            uncheckedBounds: (
                lower: min(max(visibleStart - horizontalOverscan, 0), requestedUpper),
                upper: requestedUpper
            )
        )
        let requestedTrackRange =
            max(firstVisibleTrack - 3, 0)
            ..< min(max(lastVisibleTrack + 3, 0), configuration.trackCount)
        let updated = TimelineViewportWindow(
            timeRange: requestedRange,
            trackRange: requestedTrackRange
        )
        guard force || updated != window else { return false }
        window = updated
        os_signpost(
            .event,
            log: TimelinePerformanceSignposts.log,
            name: "Viewport Window Changed",
            "tracks=%d time=%.2f-%.2f",
            requestedTrackRange.count,
            requestedRange.lowerBound,
            requestedRange.upperBound
        )
        return true
    }
}

@MainActor
final class TimelineScrollPresentationState: ObservableObject {
    @Published private(set) var horizontalOffset: CGFloat = 0
    @Published private(set) var hasResolvedHorizontalOffset = false

    func update(horizontalOffset: CGFloat) {
        hasResolvedHorizontalOffset = true
        guard abs(self.horizontalOffset - horizontalOffset) >= 0.5 else { return }
        self.horizontalOffset = horizontalOffset
    }
}

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
