// Beat This inference. Real-music parity, physical-device performance and
// decoder quality still require the validation documented in BeatMarkingResearch.md.
import CoreML
import Foundation

struct RhythmActivations: Sendable {
    let beatLogits: [Float]
    let downbeatLogits: [Float]
    let sampleRate: Double
    let hopSamples: Int

    func time(forFrame index: Int) -> Double {
        Double(index * hopSamples) / sampleRate
    }
}

enum BeatThisInferenceError: Error {
    case modelMissing
    case invalidOutput
    case invalidInput
}

struct BeatThisInference {
    static let sampleRate = 22_050.0
    static let hop = 441
    static let frameCount = 1_500
    static let sampleCount = (frameCount - 1) * hop
    static let borderFrames = 6
    static let strideFrames = frameCount - 2 * borderFrames

    private let model: MLModel

    init(
        modelURL: URL? = Bundle.main.url(forResource: "BeatThis", withExtension: "mlmodelc"),
        computeUnits: MLComputeUnits = .cpuOnly
    ) throws {
        guard let modelURL else { throw BeatThisInferenceError.modelMissing }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
    }

    func analyze(samples: [Float]) throws -> RhythmActivations {
        try samples.withUnsafeBufferPointer { try analyze(samples: $0) }
    }

    func analyze(samples: UnsafeBufferPointer<Float>) throws -> RhythmActivations {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw BeatThisInferenceError.invalidInput }
        // The upstream frontend includes the centered frame at sample zero
        // and one frame for every complete hop. Padding by six frames matches
        // the model's training border and avoids exposing chunk-edge logits.
        let totalFrames = samples.count / Self.hop + 1
        var beat = [Float](repeating: -.infinity, count: totalFrames)
        var downbeat = beat
        for start in Self.chunkStartFrames(totalFrames: totalFrames) {
            try Task.checkCancellation()
            let input = try MLMultiArray(shape: [NSNumber(value: Self.sampleCount)], dataType: .float32)
            let sampleStart = start * Self.hop
            let sourceStart = max(0, sampleStart)
            let sourceEnd = min(samples.count, sampleStart + Self.sampleCount)
            input.withUnsafeMutableBytes { bytes, _ in
                bytes.initializeMemory(as: UInt8.self, repeating: 0)
                if sourceStart < sourceEnd, let base = samples.baseAddress {
                    let destination = (sourceStart - sampleStart) * MemoryLayout<Float>.size
                    bytes.baseAddress!.advanced(by: destination).copyMemory(
                        from: base.advanced(by: sourceStart),
                        byteCount: (sourceEnd - sourceStart) * MemoryLayout<Float>.size
                    )
                }
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: input)])
            let output = try model.prediction(from: provider)
            guard let b = output.featureValue(for: "beat")?.multiArrayValue,
                  let d = output.featureValue(for: "downbeat")?.multiArrayValue,
                  b.count == Self.frameCount, d.count == Self.frameCount else {
                throw BeatThisInferenceError.invalidOutput
            }
            for frame in Self.borderFrames..<(Self.frameCount - Self.borderFrames) {
                let global = start + frame
                guard global >= 0, global < totalFrames, beat[global] == -.infinity else { continue }
                let beatValue = b[frame].floatValue
                let downbeatValue = d[frame].floatValue
                guard beatValue.isFinite, downbeatValue.isFinite else { throw BeatThisInferenceError.invalidOutput }
                beat[global] = beatValue
                downbeat[global] = downbeatValue
            }
        }
        guard beat.allSatisfy(\.isFinite), downbeat.allSatisfy(\.isFinite) else {
            throw BeatThisInferenceError.invalidOutput
        }
        return RhythmActivations(beatLogits: beat, downbeatLogits: downbeat,
                                 sampleRate: Self.sampleRate, hopSamples: Self.hop)
    }

    static func chunkStartFrames(totalFrames: Int) -> [Int] {
        guard totalFrames > 0 else { return [] }
        var starts: [Int] = []
        var start = -borderFrames
        while start < totalFrames - borderFrames {
            starts.append(start)
            start += strideFrames
        }
        if totalFrames > strideFrames {
            starts[starts.count - 1] = totalFrames - (frameCount - borderFrames)
        }
        return starts
    }

}
