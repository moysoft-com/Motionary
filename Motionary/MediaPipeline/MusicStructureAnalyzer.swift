import Accelerate
import Foundation

/// Beat-synchronous spectral novelty and dynamic-contrast analysis. Scores are
/// rankings, not calibrated probabilities; see BeatMarkingResearch.md.
struct MusicStructureAnalyzer {
    struct Features {
        let rms: Double
        let bass: Double
        let spectrum: [Double]
    }
    struct Evidence {
        let accent: Double
        let boundary: Double
        let drop: Bool
        let breakStart: Bool
        let editScore: Double
    }

    static func analyze(markers: [AudioBeatMarker], samples: UnsafeBufferPointer<Float>,
                        sampleRate: Double) throws -> [Evidence] {
        guard !markers.isEmpty, sampleRate > 0, sampleRate.isFinite else { return [] }
        let size = 1024
        let transform = try vDSP.DiscreteFourierTransform<Float>(count: size, direction: .forward,
                                                               transformType: .complexComplex, ofType: Float.self)
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                 count: size, isHalfWindow: false)
        let zeros = [Float](repeating: 0, count: size)
        var features: [Features] = []
        features.reserveCapacity(markers.count)
        for index in markers.indices {
            if index & 127 == 0 { try Task.checkCancellation() }
            let startTime = markers[index].gridTime ?? markers[index].sourceTime
            let endTime = index + 1 < markers.count ? (markers[index + 1].gridTime ?? markers[index + 1].sourceTime) : startTime + 0.25
            let start = max(0, min(samples.count, Int((startTime * sampleRate).rounded())))
            let end = max(start, min(samples.count, Int((endTime * sampleRate).rounded())))
            // Sample across the interval, rather than inferring a whole beat's
            // timbre and loudness from a single 46 ms midpoint snapshot.
            let frameCount = min(8, max(1, Int(ceil(Double(end - start) / Double(size)))))
            var energy = 0.0
            var validSamples = 0
            var bands = [Double](repeating: 0, count: 12)
            var bass = 0.0
            for frame in 0..<frameCount {
                let center = start + Int((Double(end - start) * (Double(frame) + 0.5) / Double(frameCount)).rounded())
                var input = zeros
                for j in 0..<size {
                    let sample = center - size / 2 + j
                    if sample >= start, sample < end {
                        let value = samples[sample]
                        input[j] = value * window[j]
                        energy += Double(value * value)
                        validSamples += 1
                    }
                }
                var real = zeros, imag = zeros
                transform.transform(inputReal: input, inputImaginary: zeros, outputReal: &real, outputImaginary: &imag)
                for bin in 1..<(size / 2) {
                    let frequency = Double(bin) * sampleRate / Double(size)
                    let magnitude = hypot(Double(real[bin]), Double(imag[bin]))
                    if frequency < 180 { bass += magnitude * magnitude }
                    let band = min(max(Int(log2(max(frequency, 50) / 50) * 2), 0), bands.count - 1)
                    bands[band] += magnitude
                }
            }
            let norm = sqrt(bands.reduce(0) { $0 + $1 * $1 })
            if norm > 1e-12 { bands = bands.map { $0 / norm } }
            features.append(Features(rms: sqrt(energy / Double(max(validSamples, 1))),
                                     bass: sqrt(bass / Double(frameCount)) / Double(size), spectrum: bands))
        }
        let levels = features.map(\.rms).sorted()
        let typical = levels[levels.count / 2]
        let maxBass = max(features.map(\.bass).max() ?? 0, 1e-5)
        func mean(_ range: Range<Int>) -> Features {
            guard !range.isEmpty else { return Features(rms: 0, bass: 0, spectrum: [Double](repeating: 0, count: 12)) }
            var rms = 0.0, bass = 0.0, spectrum = [Double](repeating: 0, count: 12)
            for i in range {
                rms += features[i].rms; bass += features[i].bass
                for j in spectrum.indices { spectrum[j] += features[i].spectrum[j] }
            }
            let n = Double(range.count)
            return Features(rms: rms / n, bass: bass / n, spectrum: spectrum.map { $0 / n })
        }
        var result: [Evidence] = []
        for i in markers.indices {
            let preceding = mean(max(0, i - 4)..<i)
            let following = mean(i..<min(markers.count, i + 4))
            let enoughContext = i >= 3 && i + 3 < markers.count
            let dot = zip(preceding.spectrum, following.spectrum).reduce(0.0) { $0 + $1.0 * $1.1 }
            let na = sqrt(preceding.spectrum.reduce(0) { $0 + $1 * $1 })
            let nb = sqrt(following.spectrum.reduce(0) { $0 + $1 * $1 })
            let spectralChange = enoughContext && na * nb > 1e-8 ? max(0, 1 - dot / (na * nb)) : 0
            let contrast = enoughContext ? min(abs(log((following.rms + 1e-5) / (preceding.rms + 1e-5))) / 2, 1) : 0
            let boundary = min(1, 0.55 * spectralChange + 0.45 * contrast)
            let onset = markers[i].audibleOnset == nil ? 0.0 : 1.0
            let level = min(features[i].rms / max(typical * 2, 1e-5), 1)
            let low = min(features[i].bass / maxBass, 1)
            let accent = min(1, 0.4 * level + 0.25 * low + 0.2 * onset + (markers[i].isDownbeat == true ? 0.15 : 0))
            let drop = enoughContext && preceding.rms < typical * 0.7 && following.rms > max(typical, preceding.rms * 1.8) && onset > 0
            let breakStart = enoughContext && following.rms < typical * 0.65 && preceding.rms > max(typical, following.rms * 1.8)
            let score = min(1, max(0, 0.35 * markers[i].strength + (markers[i].isDownbeat == true ? 0.18 : 0)
                                        + 0.2 * accent + 0.15 * boundary + 0.12 * onset))
            result.append(Evidence(accent: accent, boundary: boundary, drop: drop, breakStart: breakStart, editScore: score))
        }
        // A single transition can be detected in several adjacent beat windows.
        // Keep the strongest local candidate so one drop/break is one event.
        func keepPeaks(_ candidates: [Int]) -> Set<Int> {
            var kept: [Int] = []
            for index in candidates.sorted(by: { result[$0].boundary > result[$1].boundary }) {
                if kept.allSatisfy({ abs($0 - index) >= 4 }) { kept.append(index) }
            }
            return Set(kept)
        }
        let drops = keepPeaks(result.indices.filter { result[$0].drop })
        let breaks = keepPeaks(result.indices.filter { result[$0].breakStart })
        return result.indices.map { index in
            let item = result[index]
            return Evidence(accent: item.accent, boundary: item.boundary,
                            drop: drops.contains(index), breakStart: breaks.contains(index),
                            editScore: item.editScore)
        }
    }
}
