import FirebaseFirestore
import Foundation

struct Suggestion: Identifiable, Codable {
    @DocumentID var id: String?
    let title: String
    let description: String
    var votes: Int
    let ownerID: String?

    // Kept only so suggestions created by older Motionary builds remain readable.
    let votedUsers: [String]?
    let normalizedTitle: String?
    let normalizationKey: String?
    let status: String?
    let createdAt: Timestamp?

    var legacyVotedUsers: [String] {
        votedUsers ?? []
    }

    var resolvedStatus: SuggestionStatus {
        SuggestionStatus(firestoreValue: status)
    }
}

enum SuggestionStatus: String, CaseIterable, Identifiable {
    case normal
    case marked
    case inProgress
    case later
    case done
    case hidden

    var id: String { rawValue }

    init(firestoreValue: String?) {
        switch firestoreValue {
        case "marked": self = .marked
        case "inProgress": self = .inProgress
        case "later": self = .later
        case "done": self = .done
        case "hidden", "rejected": self = .hidden
        default: self = .normal
        }
    }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .marked: "Marked"
        case .inProgress: "In Progress"
        case .later: "Later"
        case .done: "Done"
        case .hidden: "Hidden"
        }
    }

    var systemImage: String {
        switch self {
        case .normal: "circle"
        case .marked: "bookmark.fill"
        case .inProgress: "hammer.fill"
        case .later: "clock.fill"
        case .done: "checkmark.circle.fill"
        case .hidden: "eye.slash.fill"
        }
    }

    var sortOrder: Int {
        switch self {
        case .inProgress: 0
        case .marked: 1
        case .normal: 2
        case .later: 3
        case .done: 4
        case .hidden: 5
        }
    }
}
