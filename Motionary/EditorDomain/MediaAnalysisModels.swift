// Persisted background-removal and audio-beat analysis values.

import Foundation

enum BackgroundRemovalMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, chromaKey, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Auto"
        case .chromaKey: "Chroma key"
        case .custom: "Custom"
        }
    }
    var systemImage: String {
        switch self {
        case .automatic: "person.crop.square"
        case .chromaKey: "eyedropper"
        case .custom: "paintbrush.pointed"
        }
    }
}

struct BackgroundBrushPoint: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
}

/// Brush coordinates and diameter are normalized to the untransformed source.
struct BackgroundBrushStroke: Codable, Equatable, Hashable, Sendable {
    var points: [BackgroundBrushPoint]
    var diameter: Double
    var restores: Bool
}

struct BackgroundRemovalSettings: Codable, Equatable, Sendable {
    var mode: BackgroundRemovalMode
    var edgeRefinement: Double
    var feather: Double
    var keyColor: RGBAColor
    var tolerance: Double
    var softness: Double
    var spillSuppression: Double
    var isInverted: Bool
    var strokes: [BackgroundBrushStroke]
    var requiresForegroundMatte: Bool { mode == .automatic }

    init(
        edgeRefinement: Double = 0, feather: Double = 0,
        mode: BackgroundRemovalMode = .automatic,
        keyColor: RGBAColor = RGBAColor(red: 0, green: 1, blue: 0),
        tolerance: Double = 0.3, softness: Double = 0.1,
        spillSuppression: Double = 0.5, isInverted: Bool = false,
        strokes: [BackgroundBrushStroke] = []
    ) {
        self.mode = mode
        self.edgeRefinement = Self.bounded(edgeRefinement, to: -1...1)
        self.feather = Self.bounded(feather, to: 0...1)
        self.keyColor = keyColor
        self.tolerance = Self.bounded(tolerance, to: 0...1)
        self.softness = Self.bounded(softness, to: 0...1)
        self.spillSuppression = Self.bounded(spillSuppression, to: 0...1)
        self.isInverted = isInverted
        self.strokes = strokes
    }

    private enum CodingKeys: String, CodingKey {
        case mode, edgeRefinement, feather, keyColor, tolerance, softness
        case spillSuppression, isInverted, strokes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            edgeRefinement: try c.decodeIfPresent(Double.self, forKey: .edgeRefinement) ?? 0,
            feather: try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0,
            mode: try c.decodeIfPresent(BackgroundRemovalMode.self, forKey: .mode) ?? .automatic,
            keyColor: try c.decodeIfPresent(RGBAColor.self, forKey: .keyColor)
                ?? RGBAColor(red: 0, green: 1, blue: 0),
            tolerance: try c.decodeIfPresent(Double.self, forKey: .tolerance) ?? 0.3,
            softness: try c.decodeIfPresent(Double.self, forKey: .softness) ?? 0.1,
            spillSuppression: try c.decodeIfPresent(Double.self, forKey: .spillSuppression) ?? 0.5,
            isInverted: try c.decodeIfPresent(Bool.self, forKey: .isInverted) ?? false,
            strokes: try c.decodeIfPresent([BackgroundBrushStroke].self, forKey: .strokes) ?? []
        )
    }

    private static func bounded(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

struct BackgroundRemovalArtifact: Codable, Equatable, Sendable {
    static let currentAlgorithmVersion = 1

    var url: URL
    var sourceRange: TimeRangeValue
    var sourceFingerprint: String
    var algorithmVersion: Int

    init(
        url: URL,
        sourceRange: TimeRangeValue,
        sourceFingerprint: String,
        algorithmVersion: Int = currentAlgorithmVersion
    ) {
        self.url = url
        self.sourceRange = sourceRange
        self.sourceFingerprint = sourceFingerprint
        self.algorithmVersion = algorithmVersion
    }

    func covers(_ range: TimeRangeValue, tolerance: Double = 0.001) -> Bool {
        url.pathExtension.lowercased() == "png" || sourceRange.start <= range.start + tolerance
            && sourceRange.end >= range.end - tolerance
    }
}

struct AudioBeatMarker: Codable, Equatable, Sendable, Identifiable {
    var sourceTime: Double
    var strength: Double
    var gridTime: Double?
    var audibleOnset: Double?
    var isDownbeat: Bool?
    var editScore: Double?
    var accentScore: Double?
    var boundaryScore: Double?
    var isDrop: Bool?
    var isBreakStart: Bool?

    var id: Int64 { Int64((sourceTime * 1_000_000).rounded()) }

    init(sourceTime: Double, strength: Double, gridTime: Double? = nil, audibleOnset: Double? = nil, isDownbeat: Bool? = nil, editScore: Double? = nil) {
        self.gridTime = gridTime
        self.audibleOnset = audibleOnset
        self.isDownbeat = isDownbeat
        self.editScore = editScore
        self.accentScore = nil
        self.boundaryScore = nil
        self.isDrop = nil
        self.isBreakStart = nil
        self.sourceTime = sourceTime.isFinite ? max(sourceTime, 0) : 0
        self.strength = strength.isFinite ? min(max(strength, 0), 1) : 0
    }

    private enum CodingKeys: String, CodingKey {
        case sourceTime
        case strength, gridTime, audibleOnset, isDownbeat, editScore
        case accentScore, boundaryScore, isDrop, isBreakStart
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sourceTime: try container.decode(Double.self, forKey: .sourceTime),
            strength: try container.decodeIfPresent(Double.self, forKey: .strength) ?? 0,
            gridTime: try container.decodeIfPresent(Double.self, forKey: .gridTime),
            audibleOnset: try container.decodeIfPresent(Double.self, forKey: .audibleOnset),
            isDownbeat: try container.decodeIfPresent(Bool.self, forKey: .isDownbeat),
            editScore: try container.decodeIfPresent(Double.self, forKey: .editScore)
        )
        accentScore = try container.decodeIfPresent(Double.self, forKey: .accentScore)
        boundaryScore = try container.decodeIfPresent(Double.self, forKey: .boundaryScore)
        isDrop = try container.decodeIfPresent(Bool.self, forKey: .isDrop)
        isBreakStart = try container.decodeIfPresent(Bool.self, forKey: .isBreakStart)
    }
}

struct AudioSubbeat: Codable, Equatable, Sendable {
    var sourceTime: Double
    var division: Int
    var position: Int
    var onsetTime: Double?
}

enum AudioBeatModelPrecision: String, Codable, Hashable, Sendable {
    case fp16
    case fp32
}

enum AudioBeatMethod: String, Codable, Equatable, Sendable {
    case neuralStructured
    case neuralDirect
    case signalFallback
}

struct AudioBeatAnalysis: Codable, Equatable, Sendable {
    static let currentAlgorithmVersion = 3

    var bpm: Double
    var confidence: Double
    var markers: [AudioBeatMarker]
    var subbeats: [AudioSubbeat]
    var subbeatDivision: Int
    var method: AudioBeatMethod?
    var modelPrecision: AudioBeatModelPrecision?
    var sourceFingerprint: String
    var algorithmVersion: Int

    init(
        bpm: Double,
        confidence: Double,
        markers: [AudioBeatMarker],
        subbeats: [AudioSubbeat] = [],
        subbeatDivision: Int = 0,
        method: AudioBeatMethod? = nil,
        modelPrecision: AudioBeatModelPrecision? = nil,
        sourceFingerprint: String,
        algorithmVersion: Int = currentAlgorithmVersion
    ) {
        self.bpm = bpm.isFinite ? min(max(bpm, 0), 400) : 0
        self.confidence = confidence.isFinite ? min(max(confidence, 0), 1) : 0
        self.markers = markers
            .filter { $0.sourceTime.isFinite }
            .sorted { $0.sourceTime < $1.sourceTime }
        self.subbeats = subbeats.filter { $0.sourceTime.isFinite }.sorted { $0.sourceTime < $1.sourceTime }
        self.subbeatDivision = [2, 3, 4].contains(subbeatDivision) ? subbeatDivision : 0
        self.method = method
        self.modelPrecision = modelPrecision
        self.sourceFingerprint = sourceFingerprint
        self.algorithmVersion = algorithmVersion
    }

    private enum CodingKeys: String, CodingKey {
        case bpm
        case confidence
        case markers
        case subbeats, subbeatDivision, method, modelPrecision
        case sourceFingerprint
        case algorithmVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bpm: try container.decode(Double.self, forKey: .bpm),
            confidence: try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0,
            markers: try container.decodeIfPresent([AudioBeatMarker].self, forKey: .markers) ?? [],
            subbeats: try container.decodeIfPresent([AudioSubbeat].self, forKey: .subbeats) ?? [],
            subbeatDivision: try container.decodeIfPresent(Int.self, forKey: .subbeatDivision) ?? 0,
            method: try? container.decode(AudioBeatMethod.self, forKey: .method),
            modelPrecision: try? container.decode(AudioBeatModelPrecision.self, forKey: .modelPrecision),
            sourceFingerprint: try container.decodeIfPresent(String.self, forKey: .sourceFingerprint) ?? "",
            algorithmVersion: try container.decodeIfPresent(Int.self, forKey: .algorithmVersion)
                ?? Self.currentAlgorithmVersion
        )
    }
}

struct TimelineBeatMarker: Equatable, Identifiable {
    let sourceTime: Double
    let localTimelineTime: Double
    let strength: Double

    var id: Int64 { Int64((localTimelineTime * 1_000_000).rounded()) }
}

extension MediaTimelineItem {
    var visibleBeatMarkers: [TimelineBeatMarker] {
        guard let beatAnalysis else { return [] }
        let beatEvents = beatAnalysis.markers.map { (time: $0.sourceTime, strength: $0.strength) }
        let division = beatAnalysis.subbeatDivision
        let subdivisionEvents = beatAnalysis.subbeats.compactMap { event -> (time: Double, strength: Double)? in
            let included = division > 0 && (event.division == division || (division == 4 && event.division == 2))
            return included ? (event.sourceTime, 0.35) : nil
        }
        return (beatEvents + subdivisionEvents).flatMap { event -> [TimelineBeatMarker] in
            guard event.time >= sourceRange.start - 0.000_001,
                event.time <= sourceRange.end + 0.000_001 else { return [] }
            let localSourceTime = min(max(event.time - sourceRange.start, 0), sourceRange.duration)
            return speedMap.timelineTimes(at: localSourceTime, sourceDuration: sourceRange.duration)
                .filter { $0 >= 0.16 && $0 <= timelineDuration - 0.16 }
                .map { TimelineBeatMarker(sourceTime: event.time, localTimelineTime: $0, strength: event.strength) }
        }.sorted { $0.sourceTime < $1.sourceTime }
    }
}

extension BlendMode: Identifiable {
    enum Group: String, CaseIterable, Identifiable {
        case normal = "Normal"
        case darken = "Darken"
        case lighten = "Lighten"
        case contrast = "Contrast"
        case comparison = "Comparison"
        case component = "Component"

        var id: String { rawValue }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .darken: "Darken"
        case .multiply: "Multiply"
        case .colorBurn: "Color Burn"
        case .lighten: "Lighten"
        case .screen: "Screen"
        case .colorDodge: "Color Dodge"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .color: "Color"
        case .luminosity: "Luminosity"
        }
    }

    var group: Group {
        switch self {
        case .normal: .normal
        case .darken, .multiply, .colorBurn: .darken
        case .lighten, .screen, .colorDodge: .lighten
        case .overlay, .softLight, .hardLight: .contrast
        case .difference, .exclusion: .comparison
        case .hue, .saturation, .color, .luminosity: .component
        }
    }

    static func modes(in group: Group) -> [BlendMode] {
        allCases.filter { $0.group == group }
    }
}
