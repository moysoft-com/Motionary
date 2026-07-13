import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import Foundation

@Observable
final class SuggestionsViewModel {
    var suggestions: [Suggestion] = []
    var notice: SuggestionNotice?
    private(set) var currentUserID = Auth.auth().currentUser?.uid ?? ""

    private let db = Firestore.firestore()
    private var suggestionsListener: ListenerRegistration?
    private var votedSuggestionIDs: Set<String> = []
    private var checkedVoteSuggestionIDs: Set<String> = []
    private var voteOverrides: [String: Bool] = [:]

    func listenToSuggestions() {
        guard suggestionsListener == nil else { return }

        if let user = Auth.auth().currentUser {
            finishAuthentication(userID: user.uid)
        } else {
            Auth.auth().signInAnonymously { [weak self] result, error in
                guard let self else { return }
                guard let userID = result?.user.uid, error == nil else {
                    self.presentError(error, fallback: "Couldn’t connect to suggestions.")
                    return
                }
                self.finishAuthentication(userID: userID)
            }
        }
    }

    func isVoted(_ suggestion: Suggestion) -> Bool {
        guard let suggestionID = suggestion.id else { return false }
        if let override = voteOverrides[suggestionID] {
            return override
        }
        return votedSuggestionIDs.contains(suggestionID)
            || suggestion.legacyVotedUsers.contains(currentUserID)
    }

    func addSuggestion(title: String, description: String) {
        guard requireAuthenticatedUser() else { return }

        let normalizedTitle = Self.normalize(title)
        if let existing = suggestions.first(where: { Self.normalize($0.title) == normalizedTitle }) {
            addVoteIfNeeded(to: existing)
            return
        }

        let normalizationKey = Self.hash(normalizedTitle)
        let keyRef = db.collection("suggestionKeys").document(normalizationKey)
        let cooldownRef = db.collection("suggestionCooldowns").document(currentUserID)
        let newSuggestionRef = db.collection("suggestions").document()

        db.runTransaction({ transaction, errorPointer in
            do {
                let keySnapshot = try transaction.getDocument(keyRef)
                let cooldownSnapshot = try transaction.getDocument(cooldownRef)

                if keySnapshot.exists,
                   let existingID = keySnapshot.data()?["suggestionID"] as? String {
                    let suggestionRef = self.db.collection("suggestions").document(existingID)
                    let voteRef = suggestionRef.collection("votes").document(self.currentUserID)
                    let suggestionSnapshot = try transaction.getDocument(suggestionRef)
                    let voteSnapshot = try transaction.getDocument(voteRef)

                    guard suggestionSnapshot.exists else {
                        transaction.deleteDocument(keyRef)
                        return ["retry": true]
                    }

                    if !voteSnapshot.exists {
                        transaction.setData(self.voteData, forDocument: voteRef)
                        transaction.updateData([
                            "votes": FieldValue.increment(Int64(1)),
                            "updatedAt": FieldValue.serverTimestamp()
                        ], forDocument: suggestionRef)
                    }

                    return [
                        "duplicate": true,
                        "voteAdded": !voteSnapshot.exists
                    ]
                }

                if let lastSubmittedAt = cooldownSnapshot.data()?["lastSubmittedAt"] as? Timestamp,
                   Date().timeIntervalSince(lastSubmittedAt.dateValue()) < 20 * 60 {
                    let remaining = max(1, Int(ceil((20 * 60 - Date().timeIntervalSince(lastSubmittedAt.dateValue())) / 60)))
                    throw SuggestionMutationError.cooldown(minutes: remaining)
                }

                transaction.setData([
                    "title": title,
                    "description": description,
                    "normalizedTitle": normalizedTitle,
                    "normalizationKey": normalizationKey,
                    "ownerID": self.currentUserID,
                    "votes": 1,
                    "status": "approved",
                    "createdAt": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: newSuggestionRef)
                transaction.setData(self.voteData, forDocument: newSuggestionRef.collection("votes").document(self.currentUserID))
                transaction.setData([
                    "suggestionID": newSuggestionRef.documentID,
                    "ownerID": self.currentUserID,
                    "createdAt": FieldValue.serverTimestamp()
                ], forDocument: keyRef)
                transaction.setData([
                    "ownerID": self.currentUserID,
                    "lastSubmittedAt": FieldValue.serverTimestamp()
                ], forDocument: cooldownRef)

                return ["duplicate": false, "voteAdded": true]
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }) { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.presentError(error, fallback: "Couldn’t submit the suggestion.")
                return
            }

            let response = result as? [String: Bool]
            if response?["retry"] == true {
                self.addSuggestion(title: title, description: description)
                return
            }
            if response?["duplicate"] == true {
                self.notice = SuggestionNotice(
                    title: "Suggestion Already Exists",
                    message: response?["voteAdded"] == true
                        ? "Your vote was added to the existing suggestion."
                        : "You already voted for the existing suggestion."
                )
            } else {
                self.notice = SuggestionNotice(title: "Suggestion Submitted", message: "Thanks for helping improve Motionary.")
            }
        }
    }

    func toggleVote(for suggestion: Suggestion) {
        guard requireAuthenticatedUser(), let suggestionID = suggestion.id else { return }

        let wasVoted = isVoted(suggestion)
        voteOverrides[suggestionID] = !wasVoted
        if wasVoted {
            votedSuggestionIDs.remove(suggestionID)
        } else {
            votedSuggestionIDs.insert(suggestionID)
        }
        let suggestionRef = db.collection("suggestions").document(suggestionID)
        let voteRef = suggestionRef.collection("votes").document(currentUserID)

        db.runTransaction({ transaction, errorPointer in
            do {
                let suggestionSnapshot = try transaction.getDocument(suggestionRef)
                let voteSnapshot = try transaction.getDocument(voteRef)
                guard suggestionSnapshot.exists else { return nil }

                if voteSnapshot.exists {
                    transaction.deleteDocument(voteRef)
                    transaction.updateData([
                        "votes": FieldValue.increment(Int64(-1)),
                        "updatedAt": FieldValue.serverTimestamp()
                    ], forDocument: suggestionRef)
                } else if suggestion.legacyVotedUsers.contains(self.currentUserID) {
                    transaction.updateData([
                        "votes": FieldValue.increment(Int64(-1)),
                        "votedUsers": FieldValue.arrayRemove([self.currentUserID]),
                        "updatedAt": FieldValue.serverTimestamp()
                    ], forDocument: suggestionRef)
                } else {
                    transaction.setData(self.voteData, forDocument: voteRef)
                    transaction.updateData([
                        "votes": FieldValue.increment(Int64(1)),
                        "updatedAt": FieldValue.serverTimestamp()
                    ], forDocument: suggestionRef)
                }
                return nil
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }) { [weak self] _, error in
            if let error {
                if wasVoted {
                    self?.votedSuggestionIDs.insert(suggestionID)
                } else {
                    self?.votedSuggestionIDs.remove(suggestionID)
                }
                self?.voteOverrides.removeValue(forKey: suggestionID)
                self?.presentError(error, fallback: "Couldn’t update your vote.")
            }
        }
    }

    private func addVoteIfNeeded(to suggestion: Suggestion) {
        guard let suggestionID = suggestion.id else { return }
        if isVoted(suggestion) {
            notice = SuggestionNotice(
                title: "Suggestion Already Exists",
                message: "You already voted for the existing suggestion."
            )
            return
        }

        voteOverrides[suggestionID] = true
        votedSuggestionIDs.insert(suggestionID)
        let suggestionRef = db.collection("suggestions").document(suggestionID)
        let voteRef = suggestionRef.collection("votes").document(currentUserID)
        db.runTransaction({ transaction, errorPointer in
            do {
                let suggestionSnapshot = try transaction.getDocument(suggestionRef)
                let voteSnapshot = try transaction.getDocument(voteRef)
                guard suggestionSnapshot.exists else { return nil }
                if !voteSnapshot.exists {
                    transaction.setData(self.voteData, forDocument: voteRef)
                    transaction.updateData([
                        "votes": FieldValue.increment(Int64(1)),
                        "updatedAt": FieldValue.serverTimestamp()
                    ], forDocument: suggestionRef)
                }
                return voteSnapshot.exists
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }) { [weak self] alreadyVoted, error in
            guard let self else { return }
            if let error {
                self.voteOverrides.removeValue(forKey: suggestionID)
                self.votedSuggestionIDs.remove(suggestionID)
                self.presentError(error, fallback: "Couldn’t add your vote.")
            } else {
                self.notice = SuggestionNotice(
                    title: "Suggestion Already Exists",
                    message: (alreadyVoted as? Bool) == true
                        ? "You already voted for the existing suggestion."
                        : "Your vote was added to the existing suggestion."
                )
            }
        }
    }

    func updateSuggestion(_ suggestion: Suggestion, title: String, description: String) {
        guard requireAuthenticatedUser(), suggestion.ownerID == currentUserID, let id = suggestion.id else { return }

        let suggestionRef = db.collection("suggestions").document(id)
        let newNormalizedTitle = Self.normalize(title)
        let newKey = Self.hash(newNormalizedTitle)
        let oldKey = suggestion.normalizationKey
        let newKeyRef = db.collection("suggestionKeys").document(newKey)

        db.runTransaction({ transaction, errorPointer in
            do {
                let suggestionSnapshot = try transaction.getDocument(suggestionRef)
                let newKeySnapshot = try transaction.getDocument(newKeyRef)
                guard suggestionSnapshot.data()?["ownerID"] as? String == self.currentUserID else {
                    throw SuggestionMutationError.notOwner
                }
                if newKeySnapshot.exists,
                   newKeySnapshot.data()?["suggestionID"] as? String != id {
                    throw SuggestionMutationError.duplicateTitle
                }

                transaction.updateData([
                    "title": title,
                    "description": description,
                    "normalizedTitle": newNormalizedTitle,
                    "normalizationKey": newKey,
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: suggestionRef)
                if !newKeySnapshot.exists {
                    transaction.setData([
                        "suggestionID": id,
                        "ownerID": self.currentUserID,
                        "createdAt": FieldValue.serverTimestamp()
                    ], forDocument: newKeyRef)
                }
                if let oldKey, oldKey != newKey {
                    transaction.deleteDocument(self.db.collection("suggestionKeys").document(oldKey))
                }
                return nil
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }) { [weak self] _, error in
            if let error {
                self?.presentError(error, fallback: "Couldn’t save the suggestion.")
            }
        }
    }

    func deleteSuggestion(_ suggestion: Suggestion) {
        guard requireAuthenticatedUser(), suggestion.ownerID == currentUserID, let id = suggestion.id else { return }

        let suggestionRef = db.collection("suggestions").document(id)
        suggestionRef.collection("votes").getDocuments { [weak self] snapshot, error in
            guard let self else { return }
            if let error {
                self.presentError(error, fallback: "Couldn’t delete the suggestion.")
                return
            }

            let batch = self.db.batch()
            snapshot?.documents.forEach { batch.deleteDocument($0.reference) }
            if let key = suggestion.normalizationKey {
                batch.deleteDocument(self.db.collection("suggestionKeys").document(key))
            }
            batch.deleteDocument(suggestionRef)
            batch.commit { error in
                if let error {
                    self.presentError(error, fallback: "Couldn’t delete the suggestion.")
                }
            }
        }
    }

    func reportSuggestion(
        _ suggestion: Suggestion,
        reason: SuggestionReportReason,
        completion: @escaping (Bool) -> Void
    ) {
        guard requireAuthenticatedUser(), suggestion.ownerID != currentUserID, let suggestionID = suggestion.id else {
            completion(false)
            return
        }

        let reportID = "\(suggestionID)_\(currentUserID)"
        db.collection("suggestionReports").document(reportID).setData([
            "suggestionID": suggestionID,
            "reporterID": currentUserID,
            "reason": reason.rawValue,
            "createdAt": FieldValue.serverTimestamp(),
            "status": "pending"
        ]) { error in
            completion(error == nil)
        }
    }

    private var voteData: [String: Any] {
        ["userID": currentUserID, "createdAt": FieldValue.serverTimestamp()]
    }

    private func finishAuthentication(userID: String) {
        currentUserID = userID
        startSuggestionsListener()
    }

    private func startSuggestionsListener() {
        suggestionsListener = db.collection("suggestions")
            .order(by: "votes", descending: true)
            .limit(to: 50)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                guard let documents = snapshot?.documents else {
                    self.presentError(error, fallback: "Couldn’t load suggestions.")
                    return
                }
                self.suggestions = documents.compactMap { try? $0.data(as: Suggestion.self) }
                self.loadVoteStates(for: self.suggestions)
                self.reconcileVoteOverrides()
            }
    }

    private func loadVoteStates(for suggestions: [Suggestion]) {
        for suggestion in suggestions {
            guard
                let suggestionID = suggestion.id,
                !checkedVoteSuggestionIDs.contains(suggestionID)
            else { continue }

            checkedVoteSuggestionIDs.insert(suggestionID)
            db.collection("suggestions").document(suggestionID)
                .collection("votes").document(currentUserID)
                .getDocument { [weak self] snapshot, _ in
                    guard let self, snapshot?.exists == true else { return }
                    self.votedSuggestionIDs.insert(suggestionID)
                    self.reconcileVoteOverrides()
                }
        }
    }

    private func reconcileVoteOverrides() {
        let settledIDs = voteOverrides.compactMap { suggestionID, desiredState -> String? in
            guard let suggestion = suggestions.first(where: { $0.id == suggestionID }) else { return nil }
            let storedState = votedSuggestionIDs.contains(suggestionID)
                || suggestion.legacyVotedUsers.contains(currentUserID)
            return storedState == desiredState ? suggestionID : nil
        }
        for suggestionID in settledIDs {
            voteOverrides.removeValue(forKey: suggestionID)
        }
    }

    private func requireAuthenticatedUser() -> Bool {
        guard !currentUserID.isEmpty else {
            notice = SuggestionNotice(title: "Still Connecting", message: "Wait a moment and try again.")
            return false
        }
        return true
    }

    private func presentError(_ error: Error?, fallback: String) {
        let message = if let error {
            "\(fallback)\n\n\(error.localizedDescription)"
        } else {
            fallback
        }
        notice = SuggestionNotice(title: "Suggestions", message: message)
    }

    private static func normalize(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(scalars).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct SuggestionNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum SuggestionMutationError: LocalizedError {
    case cooldown(minutes: Int)
    case duplicateTitle
    case notOwner

    var errorDescription: String? {
        switch self {
        case .cooldown(let minutes): "You can submit another new idea in about \(minutes) minutes."
        case .duplicateTitle: "A suggestion with that title already exists."
        case .notOwner: "Only the owner can change this suggestion."
        }
    }
}

enum SuggestionReportReason: String, CaseIterable, Identifiable {
    case spam
    case abusive
    case duplicate
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spam: "Spam or advertising"
        case .abusive: "Abusive or inappropriate"
        case .duplicate: "Duplicate suggestion"
        case .other: "Something else"
        }
    }
}
