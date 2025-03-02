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
    
    // Fixed spacing between clips.
    let clipSpacing: CGFloat = 4
    // Scale: pixels per second.
    let pixelsPerSecond: CGFloat = 10
    
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
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray)
                        .frame(width: clipWidth, height: 20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(clip.id == selectedClipID ? Color.white : Color.clear, lineWidth: 2)
                        )
                        .offset(x: xPos)
                        .onTapGesture {
                            onSelectClip(clip)
                        }
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
        var accumulated: Double = 0
        var remainingX = x
        for clip in clips {
            let clipWidth = CGFloat(clip.endTime - clip.startTime) * pixelsPerSecond
            if remainingX > clipWidth + clipSpacing {
                accumulated += clip.endTime - clip.startTime
                remainingX -= (clipWidth + clipSpacing)
            } else {
                let fraction = Double(remainingX / clipWidth)
                return accumulated + fraction * (clip.endTime - clip.startTime)
            }
        }
        return totalTime
    }
    
    private func formattedTime(_ time: Double) -> String {
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
