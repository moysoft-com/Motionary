// Timeline ruler labels, tick marks, and snap-guide presentation.

import SwiftUI
import UIKit

struct TimelineSnapGuideLine: View {
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.yellow.opacity(0.9))
            .frame(width: 1.5, height: max(height, 1))
            .shadow(color: Color.yellow.opacity(0.4), radius: 6)
    }
}

struct TimelineRulerSample: Equatable {
    static let collapseDistance: CGFloat = 60

    let horizontalOffset: CGFloat
    let collapseOffset: CGFloat
    let pixelsPerSecond: CGFloat
    let duration: Double
}

struct TimelineRulerOverlay: UIViewRepresentable {
    let scrollState: TimelineScrollPresentationState

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TimelineRulerSurface {
        let view = TimelineRulerSurface()
        context.coordinator.scrollState = scrollState
        scrollState.attachRuler(view)
        return view
    }

    func updateUIView(_ view: TimelineRulerSurface, context: Context) {
        guard context.coordinator.scrollState !== scrollState else { return }
        context.coordinator.scrollState?.detachRuler(view)
        context.coordinator.scrollState = scrollState
        scrollState.attachRuler(view)
    }

    static func dismantleUIView(_ view: TimelineRulerSurface, coordinator: Coordinator) {
        coordinator.scrollState?.detachRuler(view)
    }

    final class Coordinator {
        weak var scrollState: TimelineScrollPresentationState?
    }
}

/// Keep a viewport of ruler content on either side of the visible section.
/// Scrolling moves the band as a unit and leaves overlapping sections intact.
final class TimelineRulerSurface: UIView {
    private struct Layout: Equatable {
        let width: CGFloat
        let pixelsPerSecond: CGFloat
        let duration: Double
        let tileWidth: CGFloat

        var projectEndX: CGFloat { width / 2 + CGFloat(duration) * pixelsPerSecond }
    }

    private let band = CALayer()
    private var tiles: [Int: CALayer] = [:]
    private var sample: TimelineRulerSample?
    private var renderedLayout: Layout?
    private var renderedTileIndex: Int?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true
        isOpaque = false
        band.anchorPoint = .zero
        layer.addSublayer(band)
        registerForTraitChanges([
            UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self, UITraitDisplayScale.self,
        ]) { (view: TimelineRulerSurface, _) in
            view.renderedLayout = nil
            view.updateBand()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateBand()
    }

    func presentPlaybackMotion(_ motion: TimelinePlaybackMotion?) {
        if let motion {
            motion.apply(to: band, keyPath: "position.x")
        } else {
            band.removeAnimation(forKey: TimelinePlaybackMotion.animationKey)
        }
    }

    func present(_ sample: TimelineRulerSample, animated: Bool = false) {
        let previousY = animated ? band.presentation()?.position.y ?? band.position.y : band.position.y
        let didChangeCollapseOffset = self.sample?.collapseOffset != sample.collapseOffset
        self.sample = sample
        updateBand()
        guard didChangeCollapseOffset else { return }
        band.removeAnimation(forKey: "rulerSnap")
        guard animated, !UIAccessibility.isReduceMotionEnabled, previousY != band.position.y else { return }
        let snap = CABasicAnimation(keyPath: "position.y")
        snap.fromValue = previousY
        snap.toValue = band.position.y
        snap.duration = 0.18
        snap.timingFunction = CAMediaTimingFunction(name: .easeOut)
        band.add(snap, forKey: "rulerSnap")
    }

    private func updateBand() {
        guard let sample, bounds.width > 0 else { return }
        let layout = Layout(
            width: bounds.width,
            pixelsPerSecond: max(sample.pixelsPerSecond, 1),
            duration: sample.duration > 0 ? sample.duration : 4,
            tileWidth: max(pixelAligned(bounds.width), 1)
        )
        let tileIndex = Int(floor(sample.horizontalOffset / layout.tileWidth))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if renderedLayout != layout {
            for tile in tiles.values { tile.removeFromSuperlayer() }
            tiles.removeAll(keepingCapacity: true)
            renderedLayout = layout
            renderedTileIndex = nil
        }
        if renderedTileIndex != tileIndex {
            updateTiles(around: tileIndex, layout: layout)
            renderedTileIndex = tileIndex
        }
        let progress = sample.collapseOffset / TimelineRulerSample.collapseDistance
        let y = -15 * progress * progress * (3 - 2 * progress)
        band.position = CGPoint(x: band.bounds.minX - pixelAligned(sample.horizontalOffset), y: y)
        CATransaction.commit()
    }

    private func updateTiles(around index: Int, layout: Layout) {
        let indices = (index - 1)...(index + 1)
        let origin = CGFloat(indices.lowerBound) * layout.tileWidth
        band.bounds = CGRect(x: origin, y: 0, width: layout.tileWidth * 3, height: 30)
        for index in tiles.keys where !indices.contains(index) {
            tiles.removeValue(forKey: index)?.removeFromSuperlayer()
        }
        for index in indices where tiles[index] == nil {
            let tile = makeTile(at: CGFloat(index) * layout.tileWidth, layout: layout)
            tiles[index] = tile
            band.addSublayer(tile)
        }
    }

    private func makeTile(at origin: CGFloat, layout: Layout) -> CALayer {
        let tile = CALayer()
        // Leave room for the stroke on either side of a tile boundary.
        let tileStart = origin - 1
        tile.frame = CGRect(x: tileStart, y: 0, width: layout.tileWidth + 2, height: 30)
        let majorTicks = CAShapeLayer()
        let minorTicks = CAShapeLayer()
        majorTicks.frame = tile.bounds
        minorTicks.frame = tile.bounds
        majorTicks.lineWidth = 1.1
        minorTicks.lineWidth = 0.8
        tile.addSublayer(minorTicks)
        tile.addSublayer(majorTicks)
        let color = UIColor.label.resolvedColor(with: traitCollection)
        majorTicks.strokeColor = color.withAlphaComponent(0.48).cgColor
        minorTicks.strokeColor = color.withAlphaComponent(0.16).cgColor
        let font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), compatibleWith: traitCollection)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.withAlphaComponent(0.62),
        ]
        let majorInterval = rulerMajorInterval(for: layout.pixelsPerSecond)
        let minorInterval = rulerMinorInterval(majorInterval: majorInterval, pixelsPerSecond: layout.pixelsPerSecond)
        let majorStride = Int((majorInterval / minorInterval).rounded())
        let startX = layout.width / 2
        let end = origin + layout.tileWidth
        let firstTime = max(Double((origin - startX) / layout.pixelsPerSecond), 0)
        let lastTime = min(Double((end - startX) / layout.pixelsPerSecond), layout.duration)
        let first = Int(floor(firstTime / minorInterval))
        let last = min(Int(ceil(lastTime / minorInterval)), Int(floor(layout.duration / minorInterval + 1e-9)))
        let majorPath = CGMutablePath()
        let minorPath = CGMutablePath()

        if first <= last {
            for index in first...last {
                let time = Double(index) * minorInterval
                let tickX = pixelAligned(startX + CGFloat(time) * layout.pixelsPerSecond)
                guard tickX >= origin, tickX < end else { continue }
                let x = tickX - tileStart
                let isMajor = index.isMultiple(of: majorStride)
                let tick = isMajor ? majorTicks : minorTicks
                guard tickX + tick.lineWidth / 2 <= layout.projectEndX else { continue }
                let path = isMajor ? majorPath : minorPath
                path.move(to: CGPoint(x: x, y: isMajor ? 5 : 17))
                path.addLine(to: CGPoint(x: x, y: 29))
                if isMajor {
                    let text = NSAttributedString(string: formatRulerTime(time, interval: majorInterval), attributes: attributes)
                    let size = text.size()
                    let width = ceil(size.width) + 2
                    let height = ceil(size.height)
                    let labelX = x + max(1, 22 - width / 2)
                    let frame = CGRect(x: labelX, y: 10 - height / 2, width: width, height: height)
                    let label = CATextLayer()
                    label.alignmentMode = .center
                    label.contentsScale = max(traitCollection.displayScale, 1)
                    label.frame = frame
                    label.string = text
                    tile.addSublayer(label)
                }
            }
        }
        majorTicks.path = majorPath
        minorTicks.path = minorPath
        return tile
    }

    private func rulerMajorInterval(for pixelsPerSecond: CGFloat) -> Double {
        let intervals: [Double] = [
            0.1, 0.2, 0.5,
            1, 2, 5, 10, 15, 30,
            60, 120, 300, 600
        ]
        return intervals.first { CGFloat($0) * pixelsPerSecond >= 74 } ?? 600
    }

    private func rulerMinorInterval(majorInterval: Double, pixelsPerSecond: CGFloat) -> Double {
        for divisor in [5.0, 4.0, 2.0, 1.0] {
            let interval = majorInterval / divisor
            if CGFloat(interval) * pixelsPerSecond >= 12 { return interval }
        }
        return majorInterval
    }

    private func formatRulerTime(_ time: Double, interval: Double) -> String {
        if interval < 1 { return String(format: "%.1fs", time) }
        let totalSeconds = max(Int(time.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func pixelAligned(_ value: CGFloat) -> CGFloat {
        let scale = max(traitCollection.displayScale, 1)
        return (value * scale).rounded() / scale
    }
}
