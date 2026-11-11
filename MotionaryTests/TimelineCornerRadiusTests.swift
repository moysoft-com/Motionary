import CoreGraphics
import Foundation
import Testing
@testable import Motionary

struct TimelineCornerRadiusTests {
    @Test func backgroundExtendsPastProjectOnlyForThePreviewedLayer() {
        let visible = 0.0...10.0
        #expect(TimelineTrackBackgroundRange.visible(projectEnd: 10, visibleRange: visible, previewEnd: 13) == 0...13)
        #expect(TimelineTrackBackgroundRange.visible(projectEnd: 10, visibleRange: visible, previewEnd: nil) == 0...10)
        #expect(TimelineTrackBackgroundRange.visible(projectEnd: 10, visibleRange: visible, previewEnd: 7) == 0...10)
    }

    @MainActor
    @Test func viewportCanIncludeTheTemporaryDragExtension() {
        let viewport = TimelineViewportState()
        let configuration = TimelineVirtualizationConfiguration(centerPadding: 0, trackOriginY: 0,
                                                                 rowStride: 50, trackCount: 2, duration: 13)
        viewport.update(contentOffset: CGPoint(x: 90, y: 0), viewportSize: CGSize(width: 40, height: 100),
                        pixelsPerSecond: 10, configuration: configuration, force: true)
        #expect(viewport.window.timeRange.upperBound == 13)
        let background = TimelineTrackBackgroundRange.visible(projectEnd: 10,
                                                               visibleRange: viewport.window.timeRange,
                                                               previewEnd: 13)
        #expect(background?.upperBound == 13)
        #expect(!TimelineScrollSynchronizationPolicy.shouldSynchronizeOnLayout(
            isPlaying: false, isUserInteracting: false, isDraggingItem: true))
    }

    @Test func backgroundUsesOneRadiusWhenAnObjectApproachesEitherEdge() {
        func item(start: Double, duration: Double) -> TimelineItem {
            .text(TextTimelineItem(text: "A", timelineStart: start, duration: duration))
        }
        func radius(_ items: [TimelineItem]) -> CGFloat {
            TimelineTrackBackgroundRadius.calculate(items: items, range: 0...10, pixelsPerSecond: 10,
                                                    itemRadius: 3, inset: 4, height: 44)
        }
        #expect(radius([item(start: 4, duration: 1)]) == 12)
        #expect(radius([item(start: 0.2, duration: 1)]) == 9)
        #expect(radius([item(start: 9.5, duration: 0.5)]) == 7)
        #expect(radius([item(start: 0.2, duration: 1), item(start: 9.5, duration: 0.5)]) == 7)
        #expect(radius([item(start: 20, duration: 1)]) == 12)
    }

    @Test func shortestItemSetsRadiusAcrossZoomLevelsAndOutsideViewport() throws {
        let short = TimelineItem.shape(ShapeTimelineItem(
            name: "Short", mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle, color: .white, width: 64, height: 64),
            timelineStart: 100, sourceRange: TimeRangeValue(start: 0, duration: 0.4)))
        let long = TimelineItem.shape(ShapeTimelineItem(
            name: "Long", mediaID: MediaID(),
            shape: ClipShape(kind: .rectangle, color: .white, width: 64, height: 64),
            timelineStart: 0, sourceRange: TimeRangeValue(start: 0, duration: 4)))
        let snapshot = TimelineRenderTrackSnapshot(track: TimelineTrack(name: "Layer", kind: .shape,
                                                                       items: [long, short]))
        let shortest = try #require(snapshot.minimumItemDuration())
        #expect(abs(shortest - 0.4) < 0.00001)
        #expect(TimelineItemCornerRadius.value(shortestDuration: shortest, pixelsPerSecond: 20, height: 44) == 4)
        #expect(TimelineItemCornerRadius.value(shortestDuration: shortest, pixelsPerSecond: 100, height: 44) == 8)
        #expect(TimelineItemCornerRadius.value(shortestDuration: shortest, pixelsPerSecond: 1, height: 44) == 3)
        #expect(snapshot.minimumItemDuration(excluding: short.id) == 4)
        #expect(abs((snapshot.minimumItemDuration(excluding: long.id) ?? 0) - 0.4) < 0.00001)
    }

    @Test func tiedDurationsStayStableWhenAnItemMoves() {
        let first = TimelineItem.text(TextTimelineItem(text: "A", timelineStart: 0, duration: 1))
        let second = TimelineItem.text(TextTimelineItem(text: "B", timelineStart: 2, duration: 1))
        let snapshot = TimelineRenderTrackSnapshot(track: TimelineTrack(name: "Layer", kind: .text,
                                                                       items: [first, second]))
        #expect(snapshot.minimumItemDuration(excluding: first.id) == 1)
        #expect(snapshot.minimumItemDuration(excluding: second.id) == 1)
        #expect(TimelineItemCornerRadius.value(shortestDuration: nil, pixelsPerSecond: 20, height: 12) == 6)
    }
}
