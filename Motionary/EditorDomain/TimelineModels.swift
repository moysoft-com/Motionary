// Source media, clips, and track entities used by the editor timeline.

import CoreGraphics
import Foundation

struct MediaID: RawRepresentable, Hashable, Codable, Sendable {
    var rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct MediaAsset: Identifiable, Codable, Equatable {
    var id: MediaID
    var url: URL
    var fileName: String
    var mediaType: ClipMediaType
    var originalDuration: Double
    var naturalSize: CGSizeValue?
    var backgroundRemovalArtifact: BackgroundRemovalArtifact?

    init(id: MediaID, source: ClipSource) {
        self.id = id
        self.url = source.url
        self.fileName = source.url.lastPathComponent
        self.mediaType = source.mediaType
        self.originalDuration = source.originalDuration
        self.naturalSize = source.naturalSize
        self.backgroundRemovalArtifact = nil
    }

    var source: ClipSource {
        ClipSource(
            id: id.rawValue,
            url: url,
            mediaType: mediaType,
            originalDuration: originalDuration,
            naturalSize: naturalSize
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case url
        case fileName
        case mediaType
        case originalDuration
        case naturalSize
        case backgroundRemovalArtifact
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(MediaID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
            ?? URL(fileURLWithPath: fileName)
        mediaType = try container.decode(ClipMediaType.self, forKey: .mediaType)
        originalDuration = try container.decode(Double.self, forKey: .originalDuration)
        naturalSize = try container.decodeIfPresent(CGSizeValue.self, forKey: .naturalSize)
        backgroundRemovalArtifact = try container.decodeIfPresent(
            BackgroundRemovalArtifact.self,
            forKey: .backgroundRemovalArtifact
        )
    }
}

enum ClipShapeKind: String, Codable, CaseIterable, Identifiable {
    case rectangle
    case roundedRectangle
    case circle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle: "Rectangle"
        case .roundedRectangle: "Rounded Rectangle"
        case .circle: "Circle"
        }
    }

    var systemImage: String {
        switch self {
        case .rectangle: "rectangle.fill"
        case .roundedRectangle: "square.fill"
        case .circle: "circle.fill"
        }
    }

    var supportsCornerRadius: Bool {
        self == .roundedRectangle
    }
}

struct ClipShape: Codable, Equatable {
    var kind: ClipShapeKind
    var color: RGBAColor
    var width: AnimatableProperty<Double>
    var height: AnimatableProperty<Double>
    var cornerRadius: AnimatableProperty<Double>

    init(
        kind: ClipShapeKind,
        color: RGBAColor = .orange,
        width: Double = 400,
        height: Double = 400,
        cornerRadius: Double = 64
    ) {
        self.kind = kind
        self.color = color
        self.width = AnimatableProperty(baseValue: max(width, 1))
        self.height = AnimatableProperty(baseValue: max(height, 1))
        self.cornerRadius = AnimatableProperty(baseValue: max(cornerRadius, 0))
    }

    private enum CodingKeys: String, CodingKey {
        case kind, color, width, height, cornerRadius
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ClipShapeKind.self, forKey: .kind)
        color = try container.decodeIfPresent(RGBAColor.self, forKey: .color) ?? .orange
        width = Self.decodeProperty(from: container, key: .width, fallback: 400, minimum: 1)
        height = Self.decodeProperty(from: container, key: .height, fallback: 400, minimum: 1)
        cornerRadius = Self.decodeProperty(from: container, key: .cornerRadius, fallback: 64, minimum: 0)
    }

    private static func decodeProperty(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        fallback: Double,
        minimum: Double
    ) -> AnimatableProperty<Double> {
        if let property = try? container.decode(AnimatableProperty<Double>.self, forKey: key) {
            return property.clamped(to: minimum...8192)
        }
        let legacy = (try? container.decode(Double.self, forKey: key)) ?? fallback
        return AnimatableProperty(baseValue: max(legacy, minimum))
    }
}

/// Project-local media reference and source metadata.
struct ClipSource: Identifiable, Codable, Equatable {
    var id: UUID
    var url: URL
    var mediaType: ClipMediaType
    var originalDuration: Double
    var naturalSize: CGSizeValue?

    init(
        id: UUID = UUID(),
        url: URL,
        mediaType: ClipMediaType,
        originalDuration: Double,
        naturalSize: CGSizeValue? = nil
    ) {
        self.id = id
        self.url = url
        self.mediaType = mediaType
        self.originalDuration = max(0, originalDuration)
        self.naturalSize = naturalSize
    }
}

/// Codable bridge for persisted Core Graphics sizes.
struct CGSizeValue: Codable, Equatable {
    var width: Double
    var height: Double

    var cgSize: CGSize { CGSize(width: width, height: height) }

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    init(_ size: CGSize) {
        width = size.width
        height = size.height
    }
}

/// Timeline placement and editable state for one library media instance.
struct TimelineClip: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var mediaID: MediaID
    var mediaType: ClipMediaType
    var timelineStart: Double
    var sourceRange: TimeRangeValue
    var transform: ClipTransform
    var adjustments: AdjustmentSettings
    var effectStack: EffectStack
    var volume: AnimatableProperty<Double>
    var shape: ClipShape?
    fileprivate var pendingMigrationSource: ClipSource?

    var timelineEnd: Double { timelineStart + sourceRange.duration }

    init(
        id: UUID = UUID(),
        name: String,
        mediaID: MediaID,
        mediaType: ClipMediaType,
        timelineStart: Double,
        sourceRange: TimeRangeValue,
        transform: ClipTransform = ClipTransform(),
        adjustments: AdjustmentSettings = AdjustmentSettings(),
        effectStack: EffectStack = EffectStack(),
        volume: AnimatableProperty<Double> = AnimatableProperty(baseValue: 1),
        shape: ClipShape? = nil
    ) {
        self.id = id
        self.name = name
        self.mediaID = mediaID
        self.mediaType = mediaType
        self.timelineStart = max(0, timelineStart)
        self.sourceRange = sourceRange
        self.transform = transform
        self.adjustments = adjustments
        self.effectStack = effectStack
        self.volume = volume.clamped(to: 0...2)
        self.shape = shape
        self.pendingMigrationSource = nil
    }

    init(
        id: UUID = UUID(),
        name: String,
        source: ClipSource,
        mediaID: MediaID? = nil,
        timelineStart: Double,
        sourceRange: TimeRangeValue,
        transform: ClipTransform = ClipTransform(),
        adjustments: AdjustmentSettings = AdjustmentSettings(),
        effectStack: EffectStack = EffectStack(),
        volume: AnimatableProperty<Double> = AnimatableProperty(baseValue: 1),
        shape: ClipShape? = nil
    ) {
        self.init(
            id: id,
            name: name,
            mediaID: mediaID ?? MediaID(rawValue: source.id),
            mediaType: source.mediaType,
            timelineStart: timelineStart,
            sourceRange: sourceRange,
            transform: transform,
            adjustments: adjustments,
            effectStack: effectStack,
            volume: volume,
            shape: shape
        )
        self.pendingMigrationSource = source
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case mediaID
        case mediaType
        case source
        case timelineStart
        case sourceRange
        case transform
        case adjustments
        case effectStack
        case volume
        case shape
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        let decodedSource = try container.decodeIfPresent(ClipSource.self, forKey: .source)
        mediaID = try container.decodeIfPresent(MediaID.self, forKey: .mediaID)
            ?? MediaID(rawValue: decodedSource?.id ?? UUID())
        mediaType =
            try container.decodeIfPresent(ClipMediaType.self, forKey: .mediaType)
            ?? decodedSource?.mediaType
            ?? .video
        timelineStart = max(try container.decode(Double.self, forKey: .timelineStart), 0)
        sourceRange = try container.decode(TimeRangeValue.self, forKey: .sourceRange)
        transform = try container.decodeIfPresent(ClipTransform.self, forKey: .transform) ?? ClipTransform()
        adjustments =
            try container.decodeIfPresent(AdjustmentSettings.self, forKey: .adjustments)
            ?? AdjustmentSettings()
        effectStack =
            try container.decodeIfPresent(EffectStack.self, forKey: .effectStack)
            ?? EffectStack()

        if let property = try? container.decode(AnimatableProperty<Double>.self, forKey: .volume) {
            volume = property.clamped(to: 0...2)
        } else {
            let legacyVolume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
            volume = AnimatableProperty(baseValue: min(max(legacyVolume, 0), 2))
        }
        shape = try container.decodeIfPresent(ClipShape.self, forKey: .shape)
        pendingMigrationSource = decodedSource
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(mediaID, forKey: .mediaID)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(timelineStart, forKey: .timelineStart)
        try container.encode(sourceRange, forKey: .sourceRange)
        try container.encode(transform, forKey: .transform)
        try container.encode(adjustments, forKey: .adjustments)
        try container.encode(effectStack, forKey: .effectStack)
        try container.encode(volume, forKey: .volume)
        try container.encodeIfPresent(shape, forKey: .shape)
    }

    mutating func consumePendingMigrationSource() -> ClipSource? {
        defer { pendingMigrationSource = nil }
        return pendingMigrationSource
    }
}

/// Ordered collection of typed timeline items in the editor timeline.
struct TimelineTrack: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var kind: TrackKind
    var items: [TimelineItem]
    var isMuted: Bool
    var isLocked: Bool
    private var pendingMigrationSources: [MediaID: ClipSource]

    var clips: [TimelineClip] {
        items.compactMap { $0.legacyClip() }
    }

    init(
        id: UUID = UUID(),
        name: String,
        kind: TrackKind,
        items: [TimelineItem] = [],
        isMuted: Bool = false,
        isLocked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.items = items
        self.isMuted = isMuted
        self.isLocked = isLocked
        self.pendingMigrationSources = [:]
    }

    init(
        id: UUID = UUID(),
        name: String,
        kind: TrackKind,
        clips: [TimelineClip],
        isMuted: Bool = false,
        isLocked: Bool = false
    ) {
        let migration = Self.migrateLegacyClips(clips)
        self.init(
            id: id,
            name: name,
            kind: kind,
            items: migration.items,
            isMuted: isMuted,
            isLocked: isLocked
        )
        pendingMigrationSources = migration.sources
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case clips
        case items
        case isMuted
        case isLocked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(TrackKind.self, forKey: .kind)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        pendingMigrationSources = [:]
        if let decodedItems = try container.decodeIfPresent([TimelineItem].self, forKey: .items) {
            items = decodedItems
        } else {
            let legacyClips = try container.decodeIfPresent([TimelineClip].self, forKey: .clips) ?? []
            let migration = Self.migrateLegacyClips(legacyClips)
            items = migration.items
            pendingMigrationSources = migration.sources
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(items, forKey: .items)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(isLocked, forKey: .isLocked)
    }

    static func == (lhs: TimelineTrack, rhs: TimelineTrack) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.kind == rhs.kind
            && lhs.items == rhs.items
            && lhs.isMuted == rhs.isMuted
            && lhs.isLocked == rhs.isLocked
    }

    private static func migrateLegacyClips(
        _ clips: [TimelineClip]
    ) -> (items: [TimelineItem], sources: [MediaID: ClipSource]) {
        var migratedClips = clips
        var sources: [MediaID: ClipSource] = [:]
        for index in migratedClips.indices {
            if let source = migratedClips[index].consumePendingMigrationSource() {
                sources[migratedClips[index].mediaID] = source
            }
        }
        return (
            migratedClips.map(TimelineItem.fromLegacyClip),
            sources
        )
    }
}

extension TimelineTrack {
    /// Adjustment layers deliberately share the persisted visual track kind
    /// for schema compatibility, but a track is homogeneous: it contains
    /// either adjustment layers or regular content, never both.
    func canAcceptItem(_ item: TimelineItem) -> Bool {
        guard kind == item.requiredTrackKind || kind == .undefined else {
            return false
        }
        guard item.requiredTrackKind == .visual else { return true }
        if item.isAdjustmentLayer {
            return items.allSatisfy(\.isAdjustmentLayer)
        }
        return !items.contains(where: \.isAdjustmentLayer)
    }

    func itemIndex(id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    mutating func sortItems() {
        items.sort { $0.timelineStart < $1.timelineStart }
    }

    mutating func appendLegacyClip(_ clip: TimelineClip) {
        var migratedClip = clip
        if let source = migratedClip.consumePendingMigrationSource() {
            pendingMigrationSources[migratedClip.mediaID] = source
        }
        items.append(TimelineItem.fromLegacyClip(migratedClip))
        sortItems()
    }

    mutating func insertLegacyClip(_ clip: TimelineClip, at index: Int) {
        var migratedClip = clip
        if let source = migratedClip.consumePendingMigrationSource() {
            pendingMigrationSources[migratedClip.mediaID] = source
        }
        items.insert(
            TimelineItem.fromLegacyClip(migratedClip),
            at: min(max(index, 0), items.count)
        )
        sortItems()
    }

    @discardableResult
    mutating func removeItem(id: UUID) -> TimelineItem? {
        guard let index = itemIndex(id: id) else { return nil }
        return items.remove(at: index)
    }

    mutating func replaceLegacyClip(id: UUID, with clip: TimelineClip) {
        guard let index = itemIndex(id: id) else { return }
        var migratedClip = clip
        if let source = migratedClip.consumePendingMigrationSource() {
            pendingMigrationSources[migratedClip.mediaID] = source
        }
        items[index] = items[index].mergingLegacyClip(migratedClip)
    }

    mutating func consumePendingMigrationSources() -> [MediaID: ClipSource] {
        defer { pendingMigrationSources.removeAll() }
        return pendingMigrationSources
    }

    mutating func setTimelineStart(id: UUID, to start: Double) {
        guard let index = itemIndex(id: id) else { return }
        items[index].timelineStart = start
        sortItems()
    }
}
