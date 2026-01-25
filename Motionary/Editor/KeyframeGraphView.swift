import SwiftUI

struct Keyframe: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var time: Double
    var value: Double
}

struct KeyframeGraphView: View {
    let keyframes: [Keyframe]
    let totalTime: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.3))
                Path { path in
                    let points = normalizedPoints(in: geometry.size)
                    guard points.count > 1 else { return }
                    path.move(to: points[0])
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(Color.green, lineWidth: 2)

                ForEach(normalizedPoints(in: geometry.size), id: \.self) { point in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                        .position(point)
                }
            }
        }
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard totalTime > 0, !keyframes.isEmpty else { return [] }
        let sorted = keyframes.sorted { $0.time < $1.time }
        return sorted.map { frame in
            let x = CGFloat(frame.time / totalTime) * size.width
            let clampedValue = min(max(frame.value, 0), 1)
            let y = size.height - CGFloat(clampedValue) * size.height
            return CGPoint(x: x, y: y)
        }
    }
}
