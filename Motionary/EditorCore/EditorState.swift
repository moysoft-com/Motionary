import Foundation

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
}

@MainActor
final class TimelineState: ObservableObject {
    @Published var contentRevision = 0
    @Published var canUndo = false
    @Published var canRedo = false
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

    var isBuilding: Bool {
        if case .building = status { return true }
        return false
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
