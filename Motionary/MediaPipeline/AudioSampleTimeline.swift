import Foundation

/// Maps decoded PCM blocks to the asset's sample timeline, retaining gaps and
/// removing overlapping/preroll samples. A missing timestamp means contiguous.
struct AudioSampleTimeline {
    struct Placement: Equatable {
        let silenceFrames: Int64
        let skippedFrames: Int
    }
    private(set) var nextFrame: Int64 = 0

    mutating func place(startFrame: Int64?, frameCount: Int) -> Placement {
        guard frameCount > 0 else { return Placement(silenceFrames: 0, skippedFrames: 0) }
        let start = startFrame ?? nextFrame
        let delta = start.subtractingReportingOverflow(nextFrame)
        guard !delta.overflow else { return Placement(silenceFrames: 0, skippedFrames: frameCount) }
        // Timestamp conversion can differ by one sample at packet boundaries.
        let offset = (-1...1).contains(delta.partialValue) ? 0 : delta.partialValue
        let gap = max(offset, 0)
        let overlap = offset < 0 ? (offset <= -Int64(frameCount) ? Int64(frameCount) : -offset) : 0
        let kept = Int64(frameCount) - overlap
        let advanced = nextFrame.addingReportingOverflow(gap)
        let final = advanced.partialValue.addingReportingOverflow(kept)
        guard !advanced.overflow, !final.overflow else { return Placement(silenceFrames: 0, skippedFrames: frameCount) }
        nextFrame = final.partialValue
        return Placement(silenceFrames: gap, skippedFrames: Int(overlap))
    }
}
