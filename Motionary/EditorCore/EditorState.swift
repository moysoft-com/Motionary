import Foundation

struct ProjectItemIndexLocation: Equatable, Sendable {
    let track: Int
    let item: Int
}

/// Stable ID-to-location lookup for the editor's top-level timeline items.
///
/// Project value edits replace `TimelineItem` values frequently while their
/// array positions remain unchanged. Cached locations are therefore validated
/// in O(1) against the current project before use. A full O(N) rebuild is only
/// necessary when a structural mutation actually moved an item or introduced
/// an ID that was not present in the previous generation.
struct ProjectItemLookupIndex {
    private(set) var projectGeneration = -1
    private(set) var rebuildCount = 0
    private var locationsByID: [UUID: ProjectItemIndexLocation] = [:]

    mutating func item(
        id: UUID,
        in project: EditorProject,
        generation: Int
    ) -> TimelineItem? {
        guard let location = location(id: id, in: project, generation: generation)
        else { return nil }
        return project.tracks[location.track].items[location.item]
    }

    mutating func location(
        id: UUID,
        in project: EditorProject,
        generation: Int
    ) -> ProjectItemIndexLocation? {
        if let cached = locationsByID[id],
            project.tracks.indices.contains(cached.track),
            project.tracks[cached.track].items.indices.contains(cached.item),
            project.tracks[cached.track].items[cached.item].id == id
        {
            projectGeneration = generation
            return cached
        }

        rebuild(from: project, generation: generation)
        return locationsByID[id]
    }

    private mutating func rebuild(from project: EditorProject, generation: Int) {
        locationsByID.removeAll(keepingCapacity: true)
        for trackIndex in project.tracks.indices {
            for itemIndex in project.tracks[trackIndex].items.indices {
                locationsByID[project.tracks[trackIndex].items[itemIndex].id] =
                    ProjectItemIndexLocation(track: trackIndex, item: itemIndex)
            }
        }
        projectGeneration = generation
        rebuildCount &+= 1
    }
}

struct TimelineInvalidationScope: Equatable, Sendable {
    var affectedTrackIDs: Set<UUID>
    var affectedTimeRange: ClosedRange<Double>?
    var isStructural: Bool
    var invalidatesAllTracks: Bool

    static let all = TimelineInvalidationScope(
        affectedTrackIDs: [],
        affectedTimeRange: nil,
        isStructural: true,
        invalidatesAllTracks: true
    )

    static func tracks(
        _ trackIDs: Set<UUID>,
        timeRange: ClosedRange<Double>? = nil,
        structural: Bool = false
    ) -> TimelineInvalidationScope {
        TimelineInvalidationScope(
            affectedTrackIDs: trackIDs,
            affectedTimeRange: timeRange,
            isStructural: structural,
            invalidatesAllTracks: false
        )
    }

    mutating func formUnion(_ other: TimelineInvalidationScope) {
        if invalidatesAllTracks || other.invalidatesAllTracks {
            self = .all
            return
        }
        affectedTrackIDs.formUnion(other.affectedTrackIDs)
        isStructural = isStructural || other.isStructural
        switch (affectedTimeRange, other.affectedTimeRange) {
        case (.none, let range), (let range, .none):
            affectedTimeRange = range
        case (.some(let lhs), .some(let rhs)):
            affectedTimeRange = min(lhs.lowerBound, rhs.lowerBound)...max(lhs.upperBound, rhs.upperBound)
        }
    }
}

@MainActor
final class PlaybackState: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    @Published var isScrubbing = false
}

@MainActor
final class SelectionState: ObservableObject {
    @Published var clipID: UUID?
    @Published var trackID: UUID?
    @Published private(set) var isClipActiveAtPlayhead = false

    func updateClipActivity(_ isActive: Bool) {
        guard isClipActiveAtPlayhead != isActive else { return }
        isClipActiveAtPlayhead = isActive
    }
}

@MainActor
final class TimelineState: ObservableObject {
    @Published var contentRevision = 0
    @Published var canUndo = false
    @Published var canRedo = false
    private(set) var lastInvalidation: TimelineInvalidationScope = .all

    func invalidate(_ scope: TimelineInvalidationScope) {
        lastInvalidation = scope
        contentRevision &+= 1
    }
}

@MainActor
final class PreviewState: ObservableObject {
    enum Status: Equatable {
        case idle
        case building(generation: Int)
        case ready(generation: Int)
        case failed(String)
        case cancelled
    }

    @Published var status: Status = .idle
    @Published var contentRevision = 0
    @Published var progress = 0.0

    var isBuilding: Bool {
        if case .building = status { return true }
        return false
    }
}

/// Narrow invalidation channel for project-backed preview geometry.
///
/// Interactive edits mutate the value-model without publishing the root editor
/// object on every gesture sample. The canvas observes this state directly so
/// selection bounds and handles still follow inspector and handle edits at the
/// input rate without waking the timeline, workspaces, or editor chrome.
@MainActor
final class PreviewCanvasState: ObservableObject {
    @Published private(set) var visualRevision = 0

    func invalidateVisualGeometry() {
        visualRevision &+= 1
    }
}

@MainActor
final class ExportState: ObservableObject {
    @Published var isExporting = false
    @Published var progress = 0.0
}

enum ProjectSaveState: Equatable {
    case idle
    case saving
    case saved(Date)
    case failed(String)
}

@MainActor
final class ProjectSession: ObservableObject {
    @Published var saveState: ProjectSaveState = .idle
}
