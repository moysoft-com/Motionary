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
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
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

/// Tick paths and labels are prepared for the current viewport and one
/// viewport on either side. Scrolling moves the entire band with one layer
/// position change in the same Core Animation commit as UIKit's track scroll.
final class TimelineRulerSurface: UIView {
    private struct Layout: Equatable {
        let width: CGFloat
        let pixelsPerSecond: CGFloat
        let duration: Double
    }

    private let band = CALayer()
    private let majorTicks = CAShapeLayer()
    private let minorTicks = CAShapeLayer()
    private var labels: [CATextLayer] = []
    private var sample: TimelineRulerSample?
    private var renderedLayout: Layout?
    private var windowStart: CGFloat = 0
    private var windowOrigin: CGFloat = 0

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true
        isOpaque = false
        band.anchorPoint = .zero
        band.masksToBounds = true
        layer.addSublayer(band)
        band.addSublayer(minorTicks)
        band.addSublayer(majorTicks)
        majorTicks.lineWidth = 1.1
        minorTicks.lineWidth = 0.8
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

    func present(_ sample: TimelineRulerSample) {
        self.sample = sample
        updateBand()
    }

    private func updateBand() {
        guard let sample, bounds.width > 0 else { return }
        let layout = Layout(
            width: bounds.width,
            pixelsPerSecond: max(sample.pixelsPerSecond, 1),
            duration: sample.duration > 0 ? sample.duration : 4
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if renderedLayout != layout || sample.horizontalOffset < windowStart
            || sample.horizontalOffset >= windowStart + layout.width
        {
            windowStart = floor(sample.horizontalOffset / layout.width) * layout.width
            windowOrigin = windowStart - layout.width
            rebuildBand(layout)
            renderedLayout = layout
        }
        let progress = min(max(sample.verticalOffset / 60, 0), 1)
        let y = -15 * progress * progress * (3 - 2 * progress)
        band.position = CGPoint(x: pixelAligned(windowOrigin - sample.horizontalOffset), y: y)
        CATransaction.commit()
    }

    private func rebuildBand(_ layout: Layout) {
        let projectEndX = layout.width / 2 + CGFloat(layout.duration) * layout.pixelsPerSecond - windowOrigin
        band.bounds = CGRect(x: 0, y: 0, width: min(layout.width * 3, projectEndX + 64), height: 30)
        majorTicks.frame = band.bounds
        minorTicks.frame = band.bounds
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
        let firstTime = max(Double((windowOrigin - layout.width / 2) / layout.pixelsPerSecond), 0)
        let lastTime = min(
            Double((windowOrigin + layout.width * 3 - layout.width / 2) / layout.pixelsPerSecond),
            layout.duration
        )
        let first = Int(floor(firstTime / minorInterval))
        let last = min(Int(ceil(lastTime / minorInterval)), Int(floor(layout.duration / minorInterval + 1e-9)))
        let majorPath = CGMutablePath()
        let minorPath = CGMutablePath()
        var labelCount = 0

        if first <= last {
            for index in first...last {
                let time = Double(index) * minorInterval
                let x = pixelAligned(layout.width / 2 + CGFloat(time) * layout.pixelsPerSecond) - windowOrigin
                let isMajor = index.isMultiple(of: majorStride)
                let tick = isMajor ? majorTicks : minorTicks
                let tickFits = x + tick.lineWidth / 2 <= projectEndX
                if tickFits {
                    let path = isMajor ? majorPath : minorPath
                    path.move(to: CGPoint(x: x, y: isMajor ? 5 : 17))
                    path.addLine(to: CGPoint(x: x, y: 29))
                }
                if isMajor && tickFits {
                    let text = NSAttributedString(string: formatRulerTime(time, interval: majorInterval), attributes: attributes)
                    let size = text.size()
                    let width = ceil(size.width) + 2
                    let height = ceil(size.height)
                    let startX = layout.width / 2 - windowOrigin
                    let labelX = x + 22 - width / 2
                    let frame = CGRect(x: labelX, y: 10 - height / 2, width: width, height: height)
                    if frame.minX >= startX {
                        updateLabel(at: labelCount, text: text, frame: frame)
                        labelCount += 1
                    }
                }
            }
        }
        majorTicks.path = majorPath
        minorTicks.path = minorPath
        for label in labels.dropFirst(labelCount) { label.isHidden = true }
    }

    private func updateLabel(at index: Int, text: NSAttributedString, frame: CGRect) {
        if index == labels.count {
            let label = CATextLayer()
            label.alignmentMode = .center
            band.addSublayer(label)
            labels.append(label)
        }
        let label = labels[index]
        label.contentsScale = max(traitCollection.displayScale, 1)
        label.frame = frame
        label.string = text
        label.isHidden = false
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
