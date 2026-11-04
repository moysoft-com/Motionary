import Foundation

/// Connects neural evidence, rhythmic decoding and timing refinement. A model
/// response that cannot support a reliable path is reported as an error.
struct NeuralBeatAnalyzer {
    static let algorithmVersion = 6

    /// Evaluate decoder output after removing model extrapolation outside the
    /// audible signal. A structured path that only has a few usable beats
    /// must not prevent the direct neural decoder from being tried.
    static func selectRhythm(
        activations: RhythmActivations,
        audibleFrames: ClosedRange<Int>,
        structured: (RhythmActivations) throws -> MetricBeatDecoder.Result = MetricBeatDecoder.decode,
        direct: (RhythmActivations) throws -> MetricBeatDecoder.Result = MetricBeatDecoder.decodeDirect
    ) throws -> (MetricBeatDecoder.Result, AudioBeatMethod) {
        func usable(_ result: MetricBeatDecoder.Result) throws -> MetricBeatDecoder.Result {
            let beats = result.beats.filter { audibleFrames.contains($0.frame) }
            guard beats.count >= 3 else { throw AudioBeatAnalysisError.noReliableBeat }
            guard beats.count != result.beats.count else { return result }
            let intervals = zip(beats.dropFirst(), beats).map { $0.frame - $1.frame }.sorted()
            let median = intervals[intervals.count / 2]
            guard median > 0 else { throw AudioBeatAnalysisError.noReliableBeat }
            let bpm = 60 * activations.sampleRate / (Double(activations.hopSamples) * Double(median))
            return MetricBeatDecoder.Result(beats: beats, bpm: bpm, periodicity: result.periodicity)
        }
        do {
            return (try usable(structured(activations)), .neuralStructured)
        } catch AudioBeatAnalysisError.noReliableBeat {
            return (try usable(direct(activations)), .neuralDirect)
        }
    }

    static func analyze(samples: UnsafeBufferPointer<Float>, fingerprint: String, engine: BeatThisInference,
                        modelPrecision: AudioBeatModelPrecision) throws -> AudioBeatAnalysis {
        let activations = try engine.analyze(samples: samples)
        // A model with global context can extrapolate beats into pure leading
        // or trailing padding. Do not discard beats inside the audible region,
        // including beats without a local transient.
        let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
        guard peak > 0 else { throw AudioBeatAnalysisError.noReliableBeat }
        let silenceThreshold = peak * 0.0001
        guard let firstSound = samples.firstIndex(where: { abs($0) >= silenceThreshold }),
              let lastSound = samples.lastIndex(where: { abs($0) >= silenceThreshold }) else {
            throw AudioBeatAnalysisError.noReliableBeat
        }
        let edgeAllowance = Int((0.05 * activations.sampleRate).rounded())
        let firstFrame = (max(firstSound - edgeAllowance, 0) + activations.hopSamples - 1) / activations.hopSamples
        let lastFrame = min(lastSound + edgeAllowance, samples.count - 1) / activations.hopSamples
        guard firstFrame <= lastFrame else { throw AudioBeatAnalysisError.noReliableBeat }
        let (result, method) = try selectRhythm(activations: activations, audibleFrames: firstFrame...lastFrame)
        let downbeats = Set(MeterDecoder.decode(result.beats).map(\.beatIndex))
        var markers: [AudioBeatMarker] = []
        for (index, beat) in result.beats.enumerated() {
            try Task.checkCancellation()
            let grid = beat.frame * activations.hopSamples
            let timing = BeatTimingRefiner.refine(gridSample: grid, samples: samples, sampleRate: activations.sampleRate)
            let gridTime = Double(timing.gridSample) / activations.sampleRate
            let onsetTime = timing.onsetSample.map { Double($0) / activations.sampleRate }
            // Evaluation shows that snapping the musical grid to transients
            // reduces beat F1 and continuity. Preserve both times separately.
            guard markers.last.map({ gridTime > $0.sourceTime }) ?? true else { continue }
            markers.append(AudioBeatMarker(sourceTime: gridTime, strength: beat.probability,
                                           gridTime: gridTime, audibleOnset: onsetTime,
                                           isDownbeat: downbeats.contains(index), editScore: nil))
        }
        guard markers.count >= 3 else { throw AudioBeatAnalysisError.noReliableBeat }
        let evidence = try MusicStructureAnalyzer.analyze(markers: markers, samples: samples,
                                                          sampleRate: activations.sampleRate)
        for (index, item) in evidence.enumerated() {
            markers[index].accentScore = item.accent
            markers[index].boundaryScore = item.boundary
            markers[index].isDrop = item.drop
            markers[index].isBreakStart = item.breakStart
            markers[index].editScore = item.editScore
        }
        // Unique hypotheses for binary, ternary and quaternary subdivisions;
        // they are stored separately so existing beat snapping does not change.
        let fractions = [(1, 4), (1, 3), (1, 2), (2, 3), (3, 4)]
        var subbeats: [AudioSubbeat] = []
        for (left, right) in zip(markers, markers.dropFirst()) {
            let leftSample = Int(((left.gridTime ?? left.sourceTime) * activations.sampleRate).rounded())
            let rightSample = Int(((right.gridTime ?? right.sourceTime) * activations.sampleRate).rounded())
            let interval = rightSample - leftSample
            for (position, division) in fractions {
                let sample = leftSample + Int((Double(interval) * Double(position) / Double(division)).rounded())
                let timing = BeatTimingRefiner.refine(gridSample: sample, samples: samples, sampleRate: activations.sampleRate)
                subbeats.append(AudioSubbeat(sourceTime: Double(sample) / activations.sampleRate,
                                             division: division, position: position,
                                             onsetTime: timing.onsetSample.map { Double($0) / activations.sampleRate }))
            }
        }
        return AudioBeatAnalysis(bpm: result.bpm, confidence: result.periodicity,
                                 markers: markers, subbeats: subbeats, method: method, modelPrecision: modelPrecision,
                                 sourceFingerprint: fingerprint,
                                 algorithmVersion: Self.algorithmVersion)
    }
}
