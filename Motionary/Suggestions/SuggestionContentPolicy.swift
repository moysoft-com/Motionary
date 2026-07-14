import Foundation

enum SuggestionContentPolicy {
    static let communityURL = URL(string: "https://moysoft.com/en/community")!

    private static let blockedTerms = [
        "nazi", "porn", "kill yourself", "kys", "rape",
        "heil hitler", "vergewaltigung", "bring dich um"
    ]

    static func validationError(title: String, description: String) -> String? {
        let combined = "\(title) \(description)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        if blockedTerms.contains(where: { combined.contains($0) }) {
            return "This text conflicts with the Community Standards. Remove abusive, hateful, sexual, or violent content."
        }

        let linkCount = combined.components(separatedBy: "http://").count - 1
            + combined.components(separatedBy: "https://").count - 1
            + combined.components(separatedBy: "www.").count - 1
        if linkCount > 1 {
            return "Suggestions may contain at most one link."
        }

        if hasExcessiveRepetition(combined) {
            return "Please remove excessively repeated characters or words."
        }

        return nil
    }

    private static func hasExcessiveRepetition(_ text: String) -> Bool {
        var previous: Character?
        var runLength = 0
        for character in text {
            if character == previous {
                runLength += 1
                if runLength >= 8 { return true }
            } else {
                previous = character
                runLength = 1
            }
        }
        return false
    }
}
