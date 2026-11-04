import Foundation
struct AudioBeatMarker {
    let sourceTime: Double
    let strength: Double
    let gridTime: Double?
    let audibleOnset: Double?
    let isDownbeat: Bool?
}
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let row: [String: Any] = try data.withUnsafeBytes { bytes in
        let samples = bytes.bindMemory(to: Float.self)
        let duration = Double(samples.count) / 22050
        let count = Int(duration / 0.5)
        let markers = (0..<count).map {
            AudioBeatMarker(sourceTime: Double($0) * 0.5, strength: 0.8, gridTime: nil,
                            audibleOnset: nil, isDownbeat: nil)
        }
        let evidence = try MusicStructureAnalyzer.analyze(markers: markers, samples: samples, sampleRate: 22050)
        return ["name": url.deletingPathExtension().lastPathComponent, "duration": duration,
                "boundaries": evidence.map(\.boundary)]
    }
    let output = try JSONSerialization.data(withJSONObject: row)
    print(String(decoding: output, as: UTF8.self))
}
