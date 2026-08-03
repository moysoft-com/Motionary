// Pure canvas snapping primitives shared by every direct-manipulation gesture.

import CoreGraphics
import Foundation

struct PreviewSnapTargets: Equatable {
    static let empty = PreviewSnapTargets(x: [], y: [])

    let x: [CGFloat]
    let y: [CGFloat]

    init(x: [CGFloat], y: [CGFloat]) {
        self.x = Self.normalized(x)
        self.y = Self.normalized(y)
    }

    var isEmpty: Bool {
        x.isEmpty && y.isEmpty
    }

    private static func normalized(_ values: [CGFloat]) -> [CGFloat] {
        values
            .filter(\.isFinite)
            .sorted()
            .reduce(into: [CGFloat]()) { result, value in
                guard result.last.map({ abs($0 - value) > 0.25 }) ?? true else { return }
                result.append(value)
            }
    }
}

struct PreviewPositionSnapResult: Equatable {
    let center: CGPoint
    let lockX: PreviewAxisSnapLock?
    let lockY: PreviewAxisSnapLock?

    var guideX: CGFloat? { lockX?.guide }
    var guideY: CGFloat? { lockY?.guide }
}

struct PreviewScaleSnapResult: Equatable {
    let scale: CGFloat
    let lockX: PreviewAxisSnapLock?
    let lockY: PreviewAxisSnapLock?

    var guideX: CGFloat? { lockX?.guide }
    var guideY: CGFloat? { lockY?.guide }
}

struct PreviewAxisSnapLock: Equatable {
    let guide: CGFloat
    let anchorIndex: Int
}

struct PreviewRotationSnapResult: Equatable {
    let degrees: Double
    let guideDegrees: Double?

    var didSnap: Bool {
        guideDegrees != nil
    }
}

struct PreviewHitLayer: Equatable {
    let id: UUID
    let stackOrder: Int
}

enum PreviewHitResolver {
    static func topmost(in layers: [PreviewHitLayer]) -> UUID? {
        layers.min {
            if $0.stackOrder != $1.stackOrder {
                return $0.stackOrder < $1.stackOrder
            }
            return $0.id.uuidString < $1.id.uuidString
        }?.id
    }
}

enum PreviewSnapEngine {
    static let acquisitionDistance: CGFloat = 9
    static let releaseDistance: CGFloat = 15
    static let rotationInterval = 15.0
    static let rotationAcquisitionDistance = 2.25
    static let rotationReleaseDistance = 4.5

    static func position(
        center: CGPoint,
        anchorOffsets: [CGPoint],
        targets: PreviewSnapTargets,
        lockedX: PreviewAxisSnapLock?,
        lockedY: PreviewAxisSnapLock?,
        acquisitionDistance: CGFloat = acquisitionDistance,
        releaseDistance: CGFloat = releaseDistance
    ) -> PreviewPositionSnapResult {
        let x = axisPosition(
            center: center.x,
            anchorOffsets: anchorOffsets.map(\.x),
            targets: targets.x,
            locked: lockedX,
            acquisitionDistance: acquisitionDistance,
            releaseDistance: releaseDistance
        )
        let y = axisPosition(
            center: center.y,
            anchorOffsets: anchorOffsets.map(\.y),
            targets: targets.y,
            locked: lockedY,
            acquisitionDistance: acquisitionDistance,
            releaseDistance: releaseDistance
        )
        return PreviewPositionSnapResult(
            center: CGPoint(x: x.value, y: y.value),
            lockX: x.lock,
            lockY: y.lock
        )
    }

    static func scale(
        center: CGPoint,
        baseAnchorOffsets: [CGPoint],
        proposedScale: CGFloat,
        targets: PreviewSnapTargets,
        lockedX: PreviewAxisSnapLock?,
        lockedY: PreviewAxisSnapLock?,
        minimumScale: CGFloat,
        maximumScale: CGFloat,
        maximumSnapRatio: CGFloat,
        acquisitionDistance: CGFloat = acquisitionDistance,
        releaseDistance: CGFloat = releaseDistance
    ) -> PreviewScaleSnapResult {
        let boundedScale = min(max(proposedScale, minimumScale), maximumScale)

        let lockedCandidates = [
            lockedX.flatMap {
                scaleCandidate(
                    axis: .x,
                    center: center.x,
                    offsets: baseAnchorOffsets.map(\.x),
                    proposedScale: boundedScale,
                    targets: [$0.guide],
                    threshold: releaseDistance,
                    minimumScale: minimumScale,
                    maximumScale: maximumScale,
                    maximumSnapRatio: maximumSnapRatio,
                    requiredAnchorIndex: $0.anchorIndex
                )
            },
            lockedY.flatMap {
                scaleCandidate(
                    axis: .y,
                    center: center.y,
                    offsets: baseAnchorOffsets.map(\.y),
                    proposedScale: boundedScale,
                    targets: [$0.guide],
                    threshold: releaseDistance,
                    minimumScale: minimumScale,
                    maximumScale: maximumScale,
                    maximumSnapRatio: maximumSnapRatio,
                    requiredAnchorIndex: $0.anchorIndex
                )
            }
        ].compactMap { $0 }

        if let locked = lockedCandidates.min(by: candidateOrdering) {
            return scaleResult(from: locked)
        }

        let candidates = [
            scaleCandidate(
                axis: .x,
                center: center.x,
                offsets: baseAnchorOffsets.map(\.x),
                proposedScale: boundedScale,
                targets: targets.x,
                threshold: acquisitionDistance,
                minimumScale: minimumScale,
                maximumScale: maximumScale,
                maximumSnapRatio: maximumSnapRatio
            ),
            scaleCandidate(
                axis: .y,
                center: center.y,
                offsets: baseAnchorOffsets.map(\.y),
                proposedScale: boundedScale,
                targets: targets.y,
                threshold: acquisitionDistance,
                minimumScale: minimumScale,
                maximumScale: maximumScale,
                maximumSnapRatio: maximumSnapRatio
            )
        ].compactMap { $0 }

        guard let best = candidates.min(by: candidateOrdering) else {
            return PreviewScaleSnapResult(
                scale: boundedScale,
                lockX: nil,
                lockY: nil
            )
        }
        return scaleResult(from: best)
    }

    static func rotation(
        degrees: Double,
        lockedGuideDegrees: Double?,
        interval: Double = rotationInterval,
        acquisitionDistance: Double = rotationAcquisitionDistance,
        releaseDistance: Double = rotationReleaseDistance
    ) -> PreviewRotationSnapResult {
        guard degrees.isFinite, interval > 0 else {
            return PreviewRotationSnapResult(degrees: degrees, guideDegrees: nil)
        }

        if let lockedGuideDegrees,
            abs(degrees - lockedGuideDegrees) <= releaseDistance
        {
            return PreviewRotationSnapResult(
                degrees: lockedGuideDegrees,
                guideDegrees: lockedGuideDegrees
            )
        }

        let nearest = (degrees / interval).rounded() * interval
        guard abs(nearest - degrees) <= acquisitionDistance else {
            return PreviewRotationSnapResult(degrees: degrees, guideDegrees: nil)
        }
        return PreviewRotationSnapResult(degrees: nearest, guideDegrees: nearest)
    }

    private enum Axis {
        case x
        case y
    }

    private struct ScaleCandidate {
        let axis: Axis
        let scale: CGFloat
        let guide: CGFloat
        let distance: CGFloat
        let anchorIndex: Int
    }

    private static func axisPosition(
        center: CGFloat,
        anchorOffsets: [CGFloat],
        targets: [CGFloat],
        locked: PreviewAxisSnapLock?,
        acquisitionDistance: CGFloat,
        releaseDistance: CGFloat
    ) -> (value: CGFloat, lock: PreviewAxisSnapLock?) {
        if let locked,
            anchorOffsets.indices.contains(locked.anchorIndex)
        {
            let anchor = center + anchorOffsets[locked.anchorIndex]
            let delta = locked.guide - anchor
            if abs(delta) <= releaseDistance {
                return (center + delta, locked)
            }
        }

        guard
            let acquired = closestAxisDelta(
                center: center,
                anchorOffsets: anchorOffsets,
                targets: targets
            ),
            acquired.distance <= acquisitionDistance
        else {
            return (center, nil)
        }
        return (
            center + acquired.delta,
            PreviewAxisSnapLock(
                guide: acquired.guide,
                anchorIndex: acquired.anchorIndex
            )
        )
    }

    private static func closestAxisDelta(
        center: CGFloat,
        anchorOffsets: [CGFloat],
        targets: [CGFloat]
    ) -> (delta: CGFloat, guide: CGFloat, distance: CGFloat, anchorIndex: Int)? {
        var best: (delta: CGFloat, guide: CGFloat, distance: CGFloat, anchorIndex: Int)?
        for (anchorIndex, offset) in anchorOffsets.enumerated() {
            let anchor = center + offset
            for target in targets {
                let delta = target - anchor
                let distance = abs(delta)
                if best == nil
                    || distance < best!.distance
                    || (distance == best!.distance && target < best!.guide)
                {
                    best = (delta, target, distance, anchorIndex)
                }
            }
        }
        return best
    }

    private static func scaleCandidate(
        axis: Axis,
        center: CGFloat,
        offsets: [CGFloat],
        proposedScale: CGFloat,
        targets: [CGFloat],
        threshold: CGFloat,
        minimumScale: CGFloat,
        maximumScale: CGFloat,
        maximumSnapRatio: CGFloat,
        requiredAnchorIndex: Int? = nil
    ) -> ScaleCandidate? {
        let maximumOffset = offsets.lazy.map { abs($0) }.max() ?? 0
        let minimumUsableOffset = max(maximumOffset * 0.12, 6)
        var best: ScaleCandidate?

        for (anchorIndex, offset) in offsets.enumerated()
        where abs(offset) >= minimumUsableOffset
            && (requiredAnchorIndex == nil || requiredAnchorIndex == anchorIndex)
        {
            let proposedAnchor = center + offset * proposedScale
            for target in targets {
                let desiredScale = (target - center) / offset
                guard desiredScale.isFinite,
                    desiredScale >= minimumScale,
                    desiredScale <= maximumScale,
                    desiredScale >= proposedScale / maximumSnapRatio,
                    desiredScale <= proposedScale * maximumSnapRatio
                else { continue }

                let distance = abs(target - proposedAnchor)
                guard distance <= threshold else { continue }
                let candidate = ScaleCandidate(
                    axis: axis,
                    scale: desiredScale,
                    guide: target,
                    distance: distance,
                    anchorIndex: anchorIndex
                )
                if best == nil || candidateOrdering(candidate, best!) {
                    best = candidate
                }
            }
        }
        return best
    }

    private static func candidateOrdering(
        _ left: ScaleCandidate,
        _ right: ScaleCandidate
    ) -> Bool {
        if left.distance != right.distance {
            return left.distance < right.distance
        }
        if left.axis != right.axis {
            return left.axis == .x
        }
        return left.guide < right.guide
    }

    private static func scaleResult(from candidate: ScaleCandidate) -> PreviewScaleSnapResult {
        PreviewScaleSnapResult(
            scale: candidate.scale,
            lockX: candidate.axis == .x
                ? PreviewAxisSnapLock(
                    guide: candidate.guide,
                    anchorIndex: candidate.anchorIndex
                )
                : nil,
            lockY: candidate.axis == .y
                ? PreviewAxisSnapLock(
                    guide: candidate.guide,
                    anchorIndex: candidate.anchorIndex
                )
                : nil
        )
    }
}
