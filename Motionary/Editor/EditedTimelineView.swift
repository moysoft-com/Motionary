import SwiftUI

struct EditedTimelineView: View {
    let clips: [Clip]
    let currentTime: Double
    let totalTime: Double
    let selectedClipID: UUID?
    
    let onSelectClip: (Clip?) -> Void
    let onScrubStart: () -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    let onMoveClip: (Int, Int) -> Void
    
    // Fixed spacing between clips.
    let clipSpacing: CGFloat = 4
    // Scale: pixels per second.
    let pixelsPerSecond: CGFloat = 10

    @State private var draggingClipID: UUID? = nil
    @State private var dragOffset: CGFloat = 0
    
    var body: some View {
        VStack(spacing: 10) {
            Text("\(formattedTime(currentTime)) / \(formattedTime(totalTime))")
                .foregroundColor(.white)
            
            // Calculate total content width.
            let totalSpacing = clipSpacing * CGFloat(max(clips.count - 1, 0))
            let contentWidth = CGFloat(totalTime) * pixelsPerSecond + totalSpacing
            
            ZStack(alignment: .leading) {
                ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                    let clipDuration = clip.endTime - clip.startTime
                    let clipWidth = CGFloat(clipDuration) * pixelsPerSecond
                    let cumDuration = cumulativeDuration(upTo: index)
                    let xPos = CGFloat(cumDuration) * pixelsPerSecond + CGFloat(index) * clipSpacing
                    let isDragging = clip.id == draggingClipID
                    RoundedRectangle(cornerRadius: 4)
                        .fill(clip.mediaType == .audio ? Color.blue.opacity(0.8) : Color.gray)
                        .frame(width: clipWidth, height: 20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(clip.id == selectedClipID ? Color.white : Color.clear, lineWidth: 2)
                        )
                        .offset(x: xPos + (isDragging ? dragOffset : 0))
                        .onTapGesture {
                            onSelectClip(clip)
                        }
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if draggingClipID == nil {
                                        draggingClipID = clip.id
                                    }
                                    dragOffset = value.translation.width
                                }
                                .onEnded { value in
                                    let targetX = max(0, xPos + value.translation.width)
                                    let targetTime = time(for: targetX)
                                    let targetIndex = indexFor(time: targetTime)
                                    onMoveClip(index, targetIndex)
                                    draggingClipID = nil
                                    dragOffset = 0
                                }
                        )
                }
                
                // Draggable playhead.
                let playheadX = playheadXPosition()
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 30)
                    .offset(x: playheadX, y: -5)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                onScrubStart()
                                let newTime = time(for: value.location.x)
                                onScrubChanged(newTime)
                            }
                            .onEnded { value in
                                let newTime = time(for: value.location.x)
                                onScrubEnd(newTime)
                            }
                    )
            }
            .frame(width: contentWidth, height: 40)
            .contentShape(Rectangle())
            .onTapGesture {
                onSelectClip(nil)
            }
        }
        .frame(maxHeight: 120)
    }
    
    func cumulativeDuration(upTo index: Int) -> Double {
        var sum = 0.0
        for i in 0..<index {
            let clip = clips[i]
            sum += clip.endTime - clip.startTime
        }
        return sum
    }
    
    func playheadXPosition() -> CGFloat {
        // Determine in which clip currentTime lies.
        guard totalTime > 0 else { return 0 }
        var accumulated: Double = 0
        var gapCount = 0
        for clip in clips {
            let clipDur = clip.endTime - clip.startTime
            if currentTime > accumulated + clipDur {
                accumulated += clipDur
                gapCount += 1
            } else {
                let fraction = (currentTime - accumulated) / clipDur
                let clipXOffset = CGFloat(accumulated) * pixelsPerSecond + CGFloat(gapCount) * clipSpacing
                let offsetWithinClip = CGFloat(fraction) * (CGFloat(clipDur) * pixelsPerSecond)
                return clipXOffset + offsetWithinClip
            }
        }
        return CGFloat(totalTime) * pixelsPerSecond + CGFloat(clips.count - 1) * clipSpacing
    }
    
    func time(for x: CGFloat) -> Double {
        // Iterate through clips to determine the corresponding time.
        guard totalTime > 0 else { return 0 }
        var accumulated: Double = 0
        var remainingX = max(0, x)
        for clip in clips {
            let clipWidth = CGFloat(clip.endTime - clip.startTime) * pixelsPerSecond
            if remainingX > clipWidth + clipSpacing {
                accumulated += clip.endTime - clip.startTime
                remainingX -= (clipWidth + clipSpacing)
            } else {
                guard clipWidth > 0 else { return accumulated }
                let fraction = Double(min(max(remainingX / clipWidth, 0), 1))
                return accumulated + fraction * (clip.endTime - clip.startTime)
            }
        }
        return totalTime
    }

    func indexFor(time: Double) -> Int {
        var accumulated: Double = 0
        for (index, clip) in clips.enumerated() {
            let clipDuration = clip.endTime - clip.startTime
            if time <= accumulated + clipDuration / 2 {
                return index
            }
            accumulated += clipDuration
        }
        return max(clips.count - 1, 0)
    }
    
    private func formattedTime(_ time: Double) -> String {
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
