import Foundation
enum AudioBeatAnalysisError: Error { case noReliableBeat }
struct AudioBeatMarker {
 let sourceTime: Double
 let strength: Double
 let gridTime: Double?
 let audibleOnset: Double?
 let isDownbeat: Bool?
}
let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
let folder = URL(fileURLWithPath: CommandLine.arguments[2])
let engine = try BeatThisInference(modelURL: modelURL, computeUnits: .cpuOnly)
let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "f32" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
for file in files {
 let input = try Data(contentsOf: file, options: .mappedIfSafe)
 let row: [String: Any] = try input.withUnsafeBytes { bytes in
  let samples = bytes.bindMemory(to: Float.self)
  let activations = try engine.analyze(samples: samples)
  let b = activations.beatLogits
  let peakFrames = b.indices.filter { index in
   guard b[index] > 0 else { return false }
   return (max(0, index - 3)...min(b.count - 1, index + 3)).allSatisfy { b[index] >= b[$0] }
  }
  var direct: [Double] = []
  var group: [Int] = []
  for frame in peakFrames {
   if let last = group.last, frame - last > 1 {
    direct.append(Double(group.reduce(0, +)) / Double(group.count) / 50)
    group.removeAll(keepingCapacity: true)
   }
   group.append(frame)
  }
  if !group.isEmpty { direct.append(Double(group.reduce(0, +)) / Double(group.count) / 50) }
  let decoded = try? MetricBeatDecoder.decode(activations)
  let grid = decoded?.beats.map { Double($0.frame) / 50 } ?? []
  let refined = decoded?.beats.map { beat in Double(BeatTimingRefiner.refine(gridSample: beat.frame * 441, samples: samples, sampleRate: 22050).selectedSample) / 22050 } ?? []
  var structuralCount = 0
  var drops = 0
  var breaks = 0
  var probabilities: [Double] = []
  var downbeatTimes: [Double] = []
  if let decoded {
   let downbeats = Set(MeterDecoder.decode(decoded.beats).map(\.beatIndex))
   probabilities = decoded.beats.map(\.probability)
   downbeatTimes = decoded.beats.enumerated().compactMap { index, beat in
    downbeats.contains(index) ? Double(beat.frame) / 50 : nil
   }
   let markers = decoded.beats.enumerated().map { index, beat in
    let timing = BeatTimingRefiner.refine(gridSample: beat.frame * 441, samples: samples, sampleRate: 22050)
    return AudioBeatMarker(sourceTime: Double(timing.selectedSample) / 22050, strength: beat.probability,
                           gridTime: Double(timing.gridSample) / 22050,
                           audibleOnset: timing.onsetSample.map { Double($0) / 22050 },
                           isDownbeat: downbeats.contains(index))
   }
   let evidence = try MusicStructureAnalyzer.analyze(markers: markers, samples: samples, sampleRate: 22050)
   structuralCount = evidence.count
   drops = evidence.filter(\.drop).count
   breaks = evidence.filter(\.breakStart).count
  }
  return ["name": file.deletingPathExtension().lastPathComponent, "direct": direct, "grid": grid,
          "refined": refined, "probabilities": probabilities, "downbeats": downbeatTimes,
          "beatLogits": activations.beatLogits, "downbeatLogits": activations.downbeatLogits,
          "structureFrames": structuralCount, "dropCandidates": drops, "breakCandidates": breaks]
 }
 let json = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
 print(String(decoding: json, as: UTF8.self))
 fflush(stdout)
}
