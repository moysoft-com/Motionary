// Value types shared by timeline drag and track-reordering interactions.

import CoreGraphics
import Foundation
import SwiftUI
import os

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
        isUserInteracting: Bool,
        isDraggingItem: Bool = false
    ) -> Bool {
        !isPlaying && !isUserInteracting && !isDraggingItem
    }
}

/// AVPlayer's clock can be corrected as the decoder and audio timebase
/// synchronize. Within a playback run, only display samples reachable at
/// playback speed. An explicit seek establishes a new anchor immediately.
struct TimelinePlaybackPosition {
    private(set) var time: Double
    private var timestamp: CFTimeInterval
    private var forwardCorrection: (time: Double, timestamp: CFTimeInterval)?

    init(time: Double, timestamp: CFTimeInterval) {
        self.time = time
        self.timestamp = timestamp
    }

    mutating func accept(_ sample: Double, at now: CFTimeInterval, frameDuration: Double) -> Double {
        let advance = sample - time
        let elapsed = max(now - timestamp, 0)
        guard advance >= 0 else {
            forwardCorrection = nil
            return time
        }
        if advance > elapsed + frameDuration {
            defer { forwardCorrection = (sample, now) }
            // Drop an isolated future sample. If the clock keeps advancing
            // from the corrected position, close the gap gradually so it
            // cannot strand the ruler behind the player.
            guard let previous = forwardCorrection else { return time }
            let interval = max(now - previous.timestamp, 0)
            let sourceAdvance = sample - previous.time
            guard sourceAdvance >= 0, sourceAdvance <= interval + frameDuration else { return time }
            time += min(advance, interval * 1.25)
            timestamp = now
            return time
        }
        forwardCorrection = nil
        time = sample
        timestamp = now
        return time
    }
}

struct TimelinePlaybackMotion {
    static let animationKey = "timelinePlaybackMotion"

    let hostTime: CFTimeInterval
    let duration: CFTimeInterval
    let distance: CGFloat

    init?(
        hostTime: CFTimeInterval, refreshInterval: CFTimeInterval, pointsPerSecond: CGFloat,
        remainingDistance: CGFloat
    ) {
        guard pointsPerSecond > 0, remainingDistance > 0, refreshInterval > 0 else { return nil }
        self.hostTime = hostTime
        // Cover brief commit gaps while keeping the visual position close
        // to the player if future updates stop arriving.
        duration = min(refreshInterval * 3, 0.05, Double(remainingDistance / pointsPerSecond))
        distance = pointsPerSecond * CGFloat(duration)
    }

    func apply(to layer: CALayer, keyPath: String) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.beginTime = layer.convertTime(hostTime, from: nil)
        animation.duration = duration
        animation.fromValue = 0
        animation.toValue = -distance
        animation.isAdditive = true
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: Self.animationKey)
    }
}

@MainActor
final class TimelineViewportState: ObservableObject {
    // Prepare a short sequence once. Bound both dimensions so this cannot
    // turn a long or densely layered timeline into an eager render.
    private static let preparedWidth: CGFloat = 2_400
    private static let preparedTrackLimit = 4

    @Published private(set) var window: TimelineViewportWindow = .initial
    private var wasPinching = false

    @discardableResult
    func update(
        contentOffset: CGPoint,
        viewportSize: CGSize,
        pixelsPerSecond: CGFloat,
        configuration: TimelineVirtualizationConfiguration,
        isPinching: Bool = false,
        force: Bool = false
    ) -> Bool {
        let pinchStateChanged = wasPinching != isPinching
        wasPinching = isPinching
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
        // Each scale change supplies a fresh viewport. A small gutter covers
        // the clip edges just outside the viewport during the gesture.
        let scrollOverscan = visibleDuration * 0.9
        let horizontalOverscan = isPinching
            ? min(scrollOverscan, Double(32 / safePixelsPerSecond))
            : scrollOverscan
        let retentionMargin = isPinching ? horizontalOverscan / 2 : visibleDuration * 0.22
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
        let firstVisibleTrack = min(
            max(Int(floor((contentOffset.y - configuration.trackOriginY) / safeStride)), 0),
            configuration.trackCount
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
        let retainedTrackOverscan = isPinching ? 0 : 1
        let retainedTrackRange =
            max(firstVisibleTrack - retainedTrackOverscan, 0)..<min(max(lastVisibleTrack + retainedTrackOverscan, 0), configuration.trackCount)

        if !force, !pinchStateChanged,
            window.contains(timeRange: retainedVisibleRange),
            window.trackRange.lowerBound <= retainedTrackRange.lowerBound,
            window.trackRange.upperBound >= retainedTrackRange.upperBound
        {
            return false
        }

        let requestedUpper = min(
            visibleEnd + horizontalOverscan,
            max(timelineDuration, visibleEnd)
        )
        let fitsPreparedWindow = !isPinching && configuration.trackCount <= Self.preparedTrackLimit
            && CGFloat(timelineDuration) * safePixelsPerSecond <= Self.preparedWidth
        let requestedRange: ClosedRange<Double> = fitsPreparedWindow ? 0...timelineDuration : ClosedRange(
            uncheckedBounds: (
                lower: min(max(visibleStart - horizontalOverscan, 0), requestedUpper),
                upper: requestedUpper
            )
        )
        let trackOverscan = isPinching ? 0 : 3
        let requestedTrackRange =
            max(firstVisibleTrack - trackOverscan, 0)..<min(max(lastVisibleTrack + trackOverscan, 0), configuration.trackCount)
        let updated = TimelineViewportWindow(
            timeRange: requestedRange,
            trackRange: requestedTrackRange
        )
        guard updated != window else { return false }
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
    @Published private(set) var verticalOffset: CGFloat = 0
    private var rulerSample: TimelineRulerSample?
    private weak var ruler: TimelineRulerSurface?

    func attachRuler(_ surface: TimelineRulerSurface) {
        guard ruler !== surface else { return }
        ruler = surface
        if let rulerSample { surface.present(rulerSample) }
    }

    func detachRuler(_ surface: TimelineRulerSurface) {
        guard ruler === surface else { return }
        surface.presentPlaybackMotion(nil)
        ruler = nil
    }

    func presentRuler(_ sample: TimelineRulerSample, animated: Bool = false) {
        guard rulerSample != sample else { return }
        rulerSample = sample
        ruler?.present(sample, animated: animated)
    }

    func presentPlaybackMotion(_ motion: TimelinePlaybackMotion?) {
        ruler?.presentPlaybackMotion(motion)
    }

    func update(verticalOffset: CGFloat) {
        guard abs(self.verticalOffset - verticalOffset) >= 0.5 else { return }
        self.verticalOffset = verticalOffset
    }

    func update(horizontalOffset: CGFloat) {
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
    var fingerTranslation: CGSize = .zero
}

struct TimelineTrackDragState: Equatable {
    let trackID: UUID
    let sourceIndex: Int
    let targetIndex: Int
    let translationY: CGFloat
    var fingerTranslation: CGSize = .zero
    var fingerLocationInWindow: CGPoint? = nil
}
