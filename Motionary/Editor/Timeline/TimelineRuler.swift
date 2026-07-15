// Timeline ruler labels, tick marks, and snap-guide presentation.

import SwiftUI

struct TimelineSnapGuideLine: View {
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.yellow.opacity(0.9))
            .frame(width: 1.5, height: max(height, 1))
            .shadow(color: Color.yellow.opacity(0.4), radius: 6)
    }
}

struct EmbeddedTimelineRuler: View {
    let duration: Double
    let pixelsPerSecond: CGFloat
    let centerPadding: CGFloat

    var body: some View {
        let safePixelsPerSecond = max(pixelsPerSecond, 1)
        let majorInterval = rulerMajorInterval(for: safePixelsPerSecond)
        let minorInterval = rulerMinorInterval(
            majorInterval: majorInterval, pixelsPerSecond: safePixelsPerSecond)
        
        let chunkDuration: Double = 60 // 60 seconds per canvas chunk to prevent massive memory allocations
        let maxTime = max(duration, 4)
        let chunkCount = max(Int(ceil(maxTime / chunkDuration)), 1)

        LazyHStack(spacing: 0) {
            ForEach(0..<chunkCount, id: \.self) { chunkIndex in
                let chunkStart = Double(chunkIndex) * chunkDuration
                let chunkEnd = min(chunkStart + chunkDuration, maxTime)
                let width = CGFloat(chunkEnd - chunkStart) * safePixelsPerSecond
                
                Canvas { context, size in
                    let firstMinor = floor(chunkStart / minorInterval) * minorInterval
                    let minorCount = max(Int(ceil((chunkEnd - firstMinor) / minorInterval)), 0)

                    for index in 0...minorCount {
                        let time = firstMinor + Double(index) * minorInterval
                        guard time >= chunkStart, time <= chunkEnd else { continue }
                        let isMajor = isMultiple(time, of: majorInterval)
                        let x = CGFloat(time - chunkStart) * safePixelsPerSecond
                        
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: isMajor ? 5 : 17))
                        path.addLine(to: CGPoint(x: x, y: 29))
                        context.stroke(
                            path, with: .color(.primary.opacity(isMajor ? 0.48 : 0.16)), lineWidth: isMajor ? 1.1 : 0.8)

                        if isMajor {
                            context.draw(
                                Text(formatRulerTime(time, interval: majorInterval))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.primary.opacity(0.62)),
                                at: CGPoint(x: x + 22, y: 10)
                            )
                        }
                    }
                }
                .frame(width: width, height: 30)
            }
        }
        .padding(.leading, centerPadding)
        .padding(.trailing, centerPadding)
        .frame(height: 30)
    }

    private func rulerMajorInterval(for pixelsPerSecond: CGFloat) -> Double {
        let intervals: [Double] = [
            0.1, 0.2, 0.5,
            1, 2, 5, 10, 15, 30,
            60, 120, 300, 600
        ]
        return intervals.first { CGFloat($0) * pixelsPerSecond >= 74 } ?? intervals.last ?? 60
    }

    private func rulerMinorInterval(majorInterval: Double, pixelsPerSecond: CGFloat) -> Double {
        for divisor in [5.0, 4.0, 2.0, 1.0] {
            let interval = majorInterval / divisor
            if CGFloat(interval) * pixelsPerSecond >= 12 {
                return interval
            }
        }
        return majorInterval
    }

    private func isMultiple(_ value: Double, of interval: Double) -> Bool {
        guard interval > 0 else { return false }
        let nearest = (value / interval).rounded() * interval
        return abs(value - nearest) < 0.0001
    }

    private func formatRulerTime(_ time: Double, interval: Double) -> String {
        if interval < 1 {
            return String(format: "%.1fs", time)
        }

        let totalSeconds = max(Int(time.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct FixedTimelineRuler: View {
    let duration: Double
    let currentTime: Double
    let pixelsPerSecond: CGFloat

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let centerX = size.width / 2
                let safePixelsPerSecond = max(pixelsPerSecond, 1)
                let visibleStart = max(currentTime - Double(centerX / safePixelsPerSecond) - 1, 0)
                let visibleEnd = min(currentTime + Double(centerX / safePixelsPerSecond) + 1, max(duration, 4))
                let majorInterval = rulerMajorInterval(for: safePixelsPerSecond)
                let minorInterval = rulerMinorInterval(
                    majorInterval: majorInterval, pixelsPerSecond: safePixelsPerSecond)
                let firstMinor = floor(visibleStart / minorInterval) * minorInterval
                let minorCount = max(Int(ceil((visibleEnd - firstMinor) / minorInterval)), 0)

                for index in 0...minorCount {
                    let time = firstMinor + Double(index) * minorInterval
                    guard time >= 0, time <= max(duration, 4) else { continue }
                    let isMajor = isMultiple(time, of: majorInterval)
                    let x = centerX + CGFloat(time - currentTime) * safePixelsPerSecond
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: isMajor ? 5 : 17))
                    path.addLine(to: CGPoint(x: x, y: 29))
                    context.stroke(
                        path, with: .color(.primary.opacity(isMajor ? 0.48 : 0.16)), lineWidth: isMajor ? 1.1 : 0.8)

                    if isMajor {
                        context.draw(
                            Text(formatRulerTime(time, interval: majorInterval))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.primary.opacity(0.62)),
                            at: CGPoint(x: x + 22, y: 10)
                        )
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func rulerMajorInterval(for pixelsPerSecond: CGFloat) -> Double {
        let intervals: [Double] = [
            0.1, 0.2, 0.5,
            1, 2, 5, 10, 15, 30,
            60, 120, 300, 600
        ]
        return intervals.first { CGFloat($0) * pixelsPerSecond >= 74 } ?? intervals.last ?? 60
    }

    private func rulerMinorInterval(majorInterval: Double, pixelsPerSecond: CGFloat) -> Double {
        for divisor in [5.0, 4.0, 2.0, 1.0] {
            let interval = majorInterval / divisor
            if CGFloat(interval) * pixelsPerSecond >= 12 {
                return interval
            }
        }
        return majorInterval
    }

    private func isMultiple(_ value: Double, of interval: Double) -> Bool {
        guard interval > 0 else { return false }
        let nearest = (value / interval).rounded() * interval
        return abs(value - nearest) < 0.0001
    }

    private func formatRulerTime(_ time: Double, interval: Double) -> String {
        if interval < 1 {
            return String(format: "%.1fs", time)
        }

        let totalSeconds = max(Int(time.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
