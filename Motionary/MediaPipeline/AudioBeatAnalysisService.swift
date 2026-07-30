// On-device beat analysis using mono PCM decoding and a vDSP spectral-flux STFT.

import AVFoundation
import Accelerate
import Foundation

enum AudioBeatAnalysisError: LocalizedError {
    case noAudioTrack
    case cannotDecode
    case noReliableBeat

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            "This clip does not contain an audio track."
        case .cannotDecode:
            "The audio could not be decoded for beat analysis."
        case .noReliableBeat:
            "No reliable beat was found. Try a clip with a clearer rhythm."
        }
    }
}

struct AudioBeatAnalysisService {
    static let sampleRate = 22_050.0
    static let windowSize = 1_024
    static let hopSize = 512
    private static let onsetDisplayLead = 0.01

    private struct OnsetCandidate {
        let index: Int
        let frame: Double
        let strength: Double
    }

    func analyze(
        url: URL,
        fingerprint: String? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> AudioBeatAnalysis {
        let sourceFingerprint: String
        if let fingerprint {
            sourceFingerprint = fingerprint
        } else {
            sourceFingerprint = try await MediaFingerprint.sha256(for: url)
        }
        let task = Task.detached(priority: .userInitiated) {
            try await Self.decodeAndAnalyze(
                url: url,
                sourceFingerprint: sourceFingerprint,
                progress: progress
            )
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    static func analyze(
        samples: [Float],
        sampleRate: Double = sampleRate,
        sourceFingerprint: String = "synthetic"
    ) throws -> AudioBeatAnalysis {
        let envelope = try spectralFlux(samples: samples, sampleRate: sampleRate)
        return try detectBeatGrid(
            onsetEnvelope: envelope,
            sampleRate: sampleRate,
            sourceDuration: Double(samples.count) / sampleRate,
            sourceFingerprint: sourceFingerprint
        )
    }

    private static func decodeAndAnalyze(
        url: URL,
        sourceFingerprint: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AudioBeatAnalysis {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioBeatAnalysisError.noAudioTrack
        }
        let loadedDuration = try await asset.load(.duration).seconds
        let duration = loadedDuration.isFinite ? max(loadedDuration, 0) : 0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioBeatAnalysisError.cannotDecode }
        reader.add(output)
        guard reader.startReading() else { throw AudioBeatAnalysisError.cannotDecode }

        let transform = try vDSP.DiscreteFourierTransform<Float>(
            count: windowSize,
            direction: .forward,
            transformType: .complexComplex,
            ofType: Float.self
        )
        let window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: windowSize,
            isHalfWindow: false
        )
        var pending: [Float] = []
        pending.reserveCapacity(windowSize * 8)
        var pendingOffset = 0
        var previousSpectrum = Array(repeating: Float(0), count: windowSize / 2)
        var envelope: [Float] = []

        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if duration.isFinite, duration > 0 {
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                progress(min(max(timestamp / duration, 0), 1) * 0.72)
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            guard byteCount >= MemoryLayout<Float>.stride else { continue }

            var data = Data(count: byteCount)
            let status = data.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: bytes.baseAddress!
                )
            }
            guard status == kCMBlockBufferNoErr else { continue }
            data.withUnsafeBytes { bytes in
                pending.append(contentsOf: bytes.bindMemory(to: Float.self))
            }

            while pending.count - pendingOffset >= windowSize {
                let frame = Array(pending[pendingOffset..<(pendingOffset + windowSize)])
                envelope.append(
                    spectralFluxFrame(
                        frame,
                        window: window,
                        transform: transform,
                        previousSpectrum: &previousSpectrum
                    )
                )
                pendingOffset += hopSize
            }
            if pendingOffset >= windowSize * 16 {
                pending.removeFirst(pendingOffset)
                pendingOffset = 0
            }
        }

        guard reader.status == .completed, !envelope.isEmpty else {
            throw AudioBeatAnalysisError.cannotDecode
        }
        progress(0.8)
        let analysis = try detectBeatGrid(
            onsetEnvelope: envelope,
            sampleRate: sampleRate,
            sourceDuration: max(duration, Double(envelope.count * hopSize) / sampleRate),
            sourceFingerprint: sourceFingerprint
        )
        progress(1)
        return analysis
    }

    private static func spectralFlux(samples: [Float], sampleRate: Double) throws -> [Float] {
        guard samples.count >= windowSize else { throw AudioBeatAnalysisError.noReliableBeat }
        let transform = try vDSP.DiscreteFourierTransform<Float>(
            count: windowSize,
            direction: .forward,
            transformType: .complexComplex,
            ofType: Float.self
        )
        let window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: windowSize,
            isHalfWindow: false
        )
        var previousSpectrum = Array(repeating: Float(0), count: windowSize / 2)
        var envelope: [Float] = []
        envelope.reserveCapacity(samples.count / hopSize)
        var offset = 0
        while offset + windowSize <= samples.count {
            let frame = Array(samples[offset..<(offset + windowSize)])
            envelope.append(
                spectralFluxFrame(
                    frame,
                    window: window,
                    transform: transform,
                    previousSpectrum: &previousSpectrum
                )
            )
            offset += hopSize
        }
        return envelope
    }

    private static func spectralFluxFrame(
        _ samples: [Float],
        window: [Float],
        transform: vDSP.DiscreteFourierTransform<Float>,
        previousSpectrum: inout [Float]
    ) -> Float {
        var realInput = Array(repeating: Float(0), count: windowSize)
        for index in 0..<windowSize {
            realInput[index] = samples[index] * window[index]
        }
        let imaginaryInput = Array(repeating: Float(0), count: windowSize)
        var realOutput = imaginaryInput
        var imaginaryOutput = imaginaryInput
        transform.transform(
            inputReal: realInput,
            inputImaginary: imaginaryInput,
            outputReal: &realOutput,
            outputImaginary: &imaginaryOutput
        )

        let firstBin = 2
        let lastBin = min(Int(8_000 / sampleRate * Double(windowSize)), windowSize / 2 - 1)
        var flux: Float = 0
        for bin in firstBin...lastBin {
            let magnitude = log1p(hypot(realOutput[bin], imaginaryOutput[bin]))
            flux += max(magnitude - previousSpectrum[bin], 0)
            previousSpectrum[bin] = magnitude
        }
        return flux / Float(max(lastBin - firstBin + 1, 1))
    }

    private static func detectBeatGrid(
        onsetEnvelope rawEnvelope: [Float],
        sampleRate: Double,
        sourceDuration: Double,
        sourceFingerprint: String
    ) throws -> AudioBeatAnalysis {
        guard rawEnvelope.count >= 16, let rawPeak = rawEnvelope.max(), rawPeak > 0.000_01 else {
            throw AudioBeatAnalysisError.noReliableBeat
        }

        let envelope = try normalizedNoveltyEnvelope(rawEnvelope)

        let frameRate = sampleRate / Double(hopSize)
        let minimumLag = max(Int((frameRate * 60 / 200).rounded()), 2)
        let maximumLag = min(Int((frameRate * 60 / 60).rounded()), envelope.count / 3)
        guard maximumLag > minimumLag else { throw AudioBeatAnalysisError.noReliableBeat }

        var correlations = Array(repeating: Double(0), count: maximumLag + 1)
        for lag in minimumLag...maximumLag {
            var numerator = 0.0
            var leftEnergy = 0.0
            var rightEnergy = 0.0
            for index in lag..<envelope.count {
                let left = envelope[index]
                let right = envelope[index - lag]
                numerator += left * right
                leftEnergy += left * left
                rightEnergy += right * right
            }
            correlations[lag] = numerator / max(sqrt(leftEnergy * rightEnergy), 0.000_001)
        }

        let candidates = onsetCandidates(in: envelope, frameRate: frameRate)
        guard candidates.count >= 3 else { throw AudioBeatAnalysisError.noReliableBeat }

        guard let chosenLag = (minimumLag...maximumLag).max(by: {
            correlations[$0] * tempoWeight(forLag: $0, frameRate: frameRate)
                < correlations[$1] * tempoWeight(forLag: $1, frameRate: frameRate)
        }) else { throw AudioBeatAnalysisError.noReliableBeat }

        let previous = correlations[max(chosenLag - 1, minimumLag)]
        let center = correlations[chosenLag]
        let next = correlations[min(chosenLag + 1, maximumLag)]
        let denominator = previous - 2 * center + next
        let interpolation = abs(denominator) > 0.000_001
            ? min(max(0.5 * (previous - next) / denominator, -0.5), 0.5)
            : 0
        var fractionalLag = Double(chosenLag) + interpolation
        var bpm = frameRate * 60 / fractionalLag
        if bpm < 82, fractionalLag * 0.5 >= Double(minimumLag) {
            fractionalLag *= 0.5
            bpm *= 2
        }
        let beatFrames = fractionalLag
        let alignmentRadius = max(1.5, min(0.14 * frameRate, beatFrames * 0.28))
        let bestPhase = bestBeatPhase(
            candidates: candidates,
            beatFrames: beatFrames,
            alignmentRadius: alignmentRadius
        )

        let markers = beatMarkers(
            candidates: candidates,
            bestPhase: bestPhase,
            beatFrames: beatFrames,
            alignmentRadius: alignmentRadius,
            sampleRate: sampleRate,
            sourceDuration: sourceDuration
        )
        let averageStrength = markers.isEmpty
            ? 0
            : markers.map(\.strength).reduce(0, +) / Double(markers.count)
        let expectedBeats = max(Int(sourceDuration / max(60 / bpm, 0.001)), 1)
        let coverage = min(Double(markers.count) / Double(max(expectedBeats, 3)), 1)
        let confidence = min(max(center * 0.5 + averageStrength * 0.33 + coverage * 0.17, 0), 1)
        guard markers.count >= 3, center >= 0.16, averageStrength >= 0.12, confidence >= 0.3 else {
            throw AudioBeatAnalysisError.noReliableBeat
        }

        return AudioBeatAnalysis(
            bpm: bpm,
            confidence: confidence,
            markers: markers,
            sourceFingerprint: sourceFingerprint
        )
    }

    private static func normalizedNoveltyEnvelope(_ rawEnvelope: [Float]) throws -> [Double] {
        let radius = 8
        var envelope = Array(repeating: Double(0), count: rawEnvelope.count)
        var prefix = Array(repeating: Double(0), count: rawEnvelope.count + 1)
        for index in rawEnvelope.indices {
            prefix[index + 1] = prefix[index] + Double(rawEnvelope[index])
        }
        for index in rawEnvelope.indices {
            let lower = max(index - radius, 0)
            let upper = min(index + radius + 1, rawEnvelope.count)
            let localMean = (prefix[upper] - prefix[lower]) / Double(max(upper - lower, 1))
            envelope[index] = max(Double(rawEnvelope[index]) - localMean * 0.86, 0)
        }
        let noveltyPeak = envelope.max() ?? 0
        guard noveltyPeak > 0.000_01 else { throw AudioBeatAnalysisError.noReliableBeat }
        return envelope.map { $0 / noveltyPeak }
    }

    private static func onsetCandidates(
        in envelope: [Double],
        frameRate: Double
    ) -> [OnsetCandidate] {
        let lowerQuartile = percentile(envelope, 0.75)
        let highQuartile = percentile(envelope, 0.95)
        let threshold = max(0.08, min(0.34, lowerQuartile + (highQuartile - lowerQuartile) * 0.18))
        let peakRadius = max(Int((0.045 * frameRate).rounded()), 1)
        let minimumGap = max(Int((0.1 * frameRate).rounded()), 2)

        var rawCandidates: [OnsetCandidate] = []
        for index in 1..<(envelope.count - 1) where envelope[index] >= threshold {
            let lower = max(index - peakRadius, 0)
            let upper = min(index + peakRadius, envelope.count - 1)
            let isLocalMaximum = (lower...upper).allSatisfy { envelope[index] >= envelope[$0] }
                && (envelope[index] > envelope[index - 1] || envelope[index] > envelope[index + 1])
            if isLocalMaximum {
                rawCandidates.append(
                    OnsetCandidate(
                        index: index,
                        frame: refinedPeakFrame(at: index, in: envelope),
                        strength: envelope[index]
                    )
                )
            }
        }

        var filteredCandidates: [OnsetCandidate] = []
        for candidate in rawCandidates.sorted(by: { $0.strength > $1.strength }) {
            if filteredCandidates.allSatisfy({ abs($0.index - candidate.index) >= minimumGap }) {
                filteredCandidates.append(candidate)
            }
        }
        return filteredCandidates.sorted { $0.frame < $1.frame }
    }

    private static func bestBeatPhase(
        candidates: [OnsetCandidate],
        beatFrames: Double,
        alignmentRadius: Double
    ) -> Double {
        var bestPhase = 0.0
        var bestPhaseScore = -Double.infinity
        var phase = 0.0
        while phase < beatFrames {
            var score = 0.0
            for candidate in candidates {
                let distance = periodicDistance(
                    from: candidate.frame,
                    toPhase: phase,
                    period: beatFrames
                )
                guard distance <= alignmentRadius else { continue }
                let proximity = 1 - distance / alignmentRadius
                score += candidate.strength * proximity * proximity
            }
            if score > bestPhaseScore {
                bestPhaseScore = score
                bestPhase = phase
            }
            phase += 0.25
        }
        return bestPhase
    }

    private static func beatMarkers(
        candidates: [OnsetCandidate],
        bestPhase: Double,
        beatFrames: Double,
        alignmentRadius: Double,
        sampleRate: Double,
        sourceDuration: Double
    ) -> [AudioBeatMarker] {
        var markers: [AudioBeatMarker] = []
        var position = bestPhase
        while frameTime(position, sampleRate: sampleRate) <= sourceDuration + 0.001 {
            if let candidate = strongestCandidate(
                near: position,
                candidates: candidates,
                alignmentRadius: alignmentRadius
            ) {
                let sourceTime = min(max(frameTime(candidate.frame, sampleRate: sampleRate), 0), sourceDuration)
                if markers.last.map({ sourceTime - $0.sourceTime >= 0.1 }) ?? true {
                    markers.append(AudioBeatMarker(sourceTime: sourceTime, strength: candidate.strength))
                }
            }
            position += beatFrames
        }
        return markers
    }

    private static func strongestCandidate(
        near position: Double,
        candidates: [OnsetCandidate],
        alignmentRadius: Double
    ) -> OnsetCandidate? {
        candidates
            .filter { abs($0.frame - position) <= alignmentRadius }
            .max {
                candidateScore($0, position: position, alignmentRadius: alignmentRadius)
                    < candidateScore($1, position: position, alignmentRadius: alignmentRadius)
            }
    }

    private static func candidateScore(
        _ candidate: OnsetCandidate,
        position: Double,
        alignmentRadius: Double
    ) -> Double {
        let distance = min(abs(candidate.frame - position), alignmentRadius)
        return candidate.strength * (1 - distance / alignmentRadius * 0.35)
    }

    private static func refinedPeakFrame(at index: Int, in envelope: [Double]) -> Double {
        guard index > 0, index < envelope.count - 1 else { return Double(index) }
        let previous = envelope[index - 1]
        let center = envelope[index]
        let next = envelope[index + 1]
        let denominator = previous - 2 * center + next
        guard abs(denominator) > 0.000_001 else { return Double(index) }
        let interpolation = min(max(0.5 * (previous - next) / denominator, -0.5), 0.5)
        return Double(index) + interpolation
    }

    private static func frameTime(_ frame: Double, sampleRate: Double) -> Double {
        (frame * Double(hopSize) + Double(windowSize) * 0.5) / sampleRate - onsetDisplayLead
    }

    private static func periodicDistance(
        from frame: Double,
        toPhase phase: Double,
        period: Double
    ) -> Double {
        let offset = abs(frame - phase)
        let wrapped = offset - floor(offset / period) * period
        return min(wrapped, period - wrapped)
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sortedValues = values.sorted()
        let position = min(max(percentile, 0), 1) * Double(sortedValues.count - 1)
        let lowerIndex = Int(floor(position))
        let upperIndex = Int(ceil(position))
        guard lowerIndex != upperIndex else { return sortedValues[lowerIndex] }
        let fraction = position - Double(lowerIndex)
        return sortedValues[lowerIndex] * (1 - fraction) + sortedValues[upperIndex] * fraction
    }

    private static func tempoWeight(forLag lag: Int, frameRate: Double) -> Double {
        let bpm = frameRate * 60 / Double(lag)
        if bpm < 72 { return 0.92 }
        if bpm > 180 { return 0.9 }
        if bpm >= 90, bpm <= 150 { return 1.04 }
        return 1
    }
}
