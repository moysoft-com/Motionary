// Community feature requests and voting.

import SwiftUI

struct SuggestionsListView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = SuggestionsViewModel()
    @State private var presentedSheet: SuggestionsSheet?
    @State private var selectedSuggestion: Suggestion?
    @State private var displayedSuggestions: [Suggestion] = []
    @State private var reorderTask: Task<Void, Never>?
    @State private var selectedFilter: SuggestionFeedFilter = .active
    @State private var selectedSort: SuggestionSort = .mostVotes
    @State private var editingSuggestion: Suggestion?
    @State private var pendingDeletion: Suggestion?

    private var suggestionsRevision: [SuggestionRevision] {
        viewModel.suggestions.map(SuggestionRevision.init)
    }

    private var feedSuggestions: [Suggestion] {
        viewModel.suggestions
            .filter { selectedFilter.includes($0, currentUserID: viewModel.currentUserID) }
            .sorted(by: selectedSort.areInIncreasingOrder)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                SuggestionFilterBar(selectedFilter: $selectedFilter)
                    .padding(.bottom, 2)

                if displayedSuggestions.isEmpty {
                    emptyState
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                } else {
                    ForEach(displayedSuggestions) { suggestion in
                        SuggestionCard(
                            suggestion: suggestion,
                            isVoted: viewModel.isVoted(suggestion),
                            isOwned: suggestion.ownerID == viewModel.currentUserID,
                            onOpen: { selectedSuggestion = suggestion },
                            onVote: { viewModel.toggleVote(for: suggestion) },
                            onEdit: { editingSuggestion = suggestion },
                            onDelete: { pendingDeletion = suggestion }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .scrollIndicators(.hidden)
        .background { MotionaryTheme.background(for: colorScheme).ignoresSafeArea() }
        .navigationTitle("Suggestions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $selectedSort) {
                        ForEach(SuggestionSort.allCases) { sort in
                            Label(sort.title, systemImage: sort.systemImage)
                                .tag(sort)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort suggestions")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button { presentedSheet = .add } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add suggestion")
            }
        }
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .add:
                AddSuggestionView(viewModel: viewModel)
            }
        }
        .sheet(item: $editingSuggestion) { suggestion in
            EditSuggestionView(suggestion: suggestion, viewModel: viewModel)
        }
        .fullScreenCover(item: $selectedSuggestion) { suggestion in
            SuggestionDetailView(suggestion: suggestion, viewModel: viewModel)
        }
        .onAppear {
            viewModel.listenToSuggestions()
        }
        .onChange(of: suggestionsRevision, initial: true) { _, _ in
            stageSuggestionUpdate(feedSuggestions)
        }
        .onChange(of: selectedFilter) { _, _ in
            stageSuggestionUpdate(feedSuggestions)
        }
        .onChange(of: selectedSort) { _, _ in
            stageSuggestionUpdate(feedSuggestions)
        }
        .onDisappear {
            reorderTask?.cancel()
        }
        .confirmationDialog(
            "Delete this suggestion?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Suggestion", role: .destructive) {
                guard let pendingDeletion else { return }
                viewModel.deleteSuggestion(pendingDeletion)
                self.pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .alert(item: $viewModel.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func stageSuggestionUpdate(_ latest: [Suggestion]) {
        guard !displayedSuggestions.isEmpty else {
            withAnimation(.smooth) {
                displayedSuggestions = latest
            }
            return
        }

        let latestByID = Dictionary(uniqueKeysWithValues: latest.compactMap { suggestion in
            suggestion.id.map { ($0, suggestion) }
        })
        let existingIDs = Set(displayedSuggestions.compactMap(\.id))
        let updatedInPlace = displayedSuggestions.compactMap { suggestion in
            guard let id = suggestion.id else { return suggestion }
            return latestByID[id]
        } + latest.filter { suggestion in
            guard let id = suggestion.id else { return true }
            return !existingIDs.contains(id)
        }

        withAnimation(.snappy(duration: 0.28)) {
            displayedSuggestions = updatedInPlace
        }

        reorderTask?.cancel()
        reorderTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.42)) {
                displayedSuggestions = latest
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lightbulb.max")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(MotionaryTheme.accent)

            Text(displayedSuggestions.isEmpty && !viewModel.suggestions.isEmpty ? "Nothing here yet" : "Start the conversation")
                .font(.headline)
                .foregroundStyle(MotionaryTheme.textPrimary)

            Text(
                displayedSuggestions.isEmpty && !viewModel.suggestions.isEmpty
                    ? "No suggestions match the selected filter."
                    : "Share an idea for Motionary and let the community vote on it."
            )
                .font(.subheadline)
                .foregroundStyle(MotionaryTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(24)
    }
}

private enum SuggestionsSheet: String, Identifiable {
    case add

    var id: String { rawValue }
}

private enum SuggestionFeedFilter: String, CaseIterable, Identifiable {
    case active
    case marked
    case inProgress
    case done
    case mine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: "All"
        case .marked: "Marked"
        case .inProgress: "In Progress"
        case .done: "Done"
        case .mine: "Mine"
        }
    }

    var systemImage: String {
        switch self {
        case .active: "rectangle.stack"
        case .marked: SuggestionStatus.marked.systemImage
        case .inProgress: SuggestionStatus.inProgress.systemImage
        case .done: SuggestionStatus.done.systemImage
        case .mine: "person.fill"
        }
    }

    func includes(_ suggestion: Suggestion, currentUserID: String) -> Bool {
        switch self {
        case .active:
            [.normal, .marked, .inProgress].contains(suggestion.resolvedStatus)
        case .marked:
            suggestion.resolvedStatus == .marked
        case .inProgress:
            suggestion.resolvedStatus == .inProgress
        case .done:
            suggestion.resolvedStatus == .done
        case .mine:
            suggestion.ownerID == currentUserID
        }
    }
}

private struct SuggestionFilterBar: View {
    @Binding var selectedFilter: SuggestionFeedFilter
    @State private var hapticTrigger = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(SuggestionFeedFilter.allCases) { filter in
                    Button {
                        selectedFilter = filter
                        hapticTrigger += 1
                    } label: {
                        Label(filter.title, systemImage: filter.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .foregroundStyle(selectedFilter == filter ? Color.black : MotionaryTheme.textSecondary)
                            .background(
                                selectedFilter == filter ? MotionaryTheme.accent : Color.primary.opacity(0.07),
                                in: Capsule(style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal, 1)
        }
        .sensoryFeedback(.selection, trigger: hapticTrigger)
    }
}

private enum SuggestionSort: String, CaseIterable, Identifiable {
    case mostVotes
    case newest
    case leastVotes
    case title
    case status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mostVotes: "Most Votes"
        case .newest: "Newest"
        case .leastVotes: "Least Votes"
        case .title: "Title"
        case .status: "Status"
        }
    }

    var systemImage: String {
        switch self {
        case .mostVotes: "arrow.up"
        case .newest: "clock"
        case .leastVotes: "arrow.down"
        case .title: "textformat"
        case .status: "tag"
        }
    }

    func areInIncreasingOrder(_ lhs: Suggestion, _ rhs: Suggestion) -> Bool {
        switch self {
        case .mostVotes:
            return lhs.votes == rhs.votes ? lhs.title < rhs.title : lhs.votes > rhs.votes
        case .newest:
            if lhs.createdAt?.dateValue() == rhs.createdAt?.dateValue() {
                return (lhs.id ?? "") > (rhs.id ?? "")
            }
            return (lhs.createdAt?.dateValue() ?? .distantPast) > (rhs.createdAt?.dateValue() ?? .distantPast)
        case .leastVotes:
            return lhs.votes == rhs.votes ? lhs.title < rhs.title : lhs.votes < rhs.votes
        case .title:
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        case .status:
            return lhs.resolvedStatus.sortOrder == rhs.resolvedStatus.sortOrder
                ? lhs.votes > rhs.votes
                : lhs.resolvedStatus.sortOrder < rhs.resolvedStatus.sortOrder
        }
    }
}

private struct SuggestionRevision: Equatable {
    let id: String?
    let title: String
    let description: String
    let votes: Int
    let votedUsers: [String]
    let status: SuggestionStatus

    init(_ suggestion: Suggestion) {
        id = suggestion.id
        title = suggestion.title
        description = suggestion.description
        votes = suggestion.votes
        votedUsers = suggestion.legacyVotedUsers
        status = suggestion.resolvedStatus
    }
}

private struct SuggestionCard: View {
    let suggestion: Suggestion
    let isVoted: Bool
    let isOwned: Bool
    let onOpen: () -> Void
    let onVote: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hapticTrigger = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                hapticTrigger.toggle()
                onVote()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: isVoted ? "arrowtriangle.up.fill" : "arrowtriangle.up")
                        .font(.caption.weight(.bold))
                    Text(suggestion.votes, format: .number)
                        .font(.headline.monospacedDigit())
                        .contentTransition(.numericText())
                }
                .foregroundStyle(isVoted ? Color.black : MotionaryTheme.accent)
                .frame(width: 52, height: 58)
                .background(
                    isVoted ? MotionaryTheme.accent : Color.primary.opacity(0.07),
                    in: .rect(cornerRadius: 14, style: .continuous)
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVoted ? "Remove vote" : "Upvote")
            .accessibilityValue("\(suggestion.votes) votes")
            .sensoryFeedback(.impact(weight: .medium), trigger: hapticTrigger)
            .animation(.snappy, value: isVoted)

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(suggestion.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(MotionaryTheme.textPrimary)
                        .lineLimit(2)

                    Text(suggestion.description)
                        .font(.subheadline)
                        .foregroundStyle(MotionaryTheme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the full suggestion")
            Spacer()
            VStack(alignment: .trailing) {
                if isOwned {
                    Menu {
                        Button("Edit", systemImage: "pencil", action: onEdit)
                        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.caption.weight(.semibold))
                            .squareHitbox()
                            .foregroundStyle(MotionaryTheme.textSecondary)
                    }
                }
                Spacer()
                if suggestion.resolvedStatus != .normal {
                    SuggestionStatusBadge(status: suggestion.resolvedStatus)
                }
            }
        }
        .padding(14)
        .motionaryGlass(cornerRadius: 20)
        .contextMenu {
            if isOwned {
                Button("Edit", systemImage: "pencil", action: onEdit)
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
struct SquareHitbox: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { width = geo.size.width }
                        .onChange(of: geo.size.width) { _, newValue in
                            width = newValue
                        }
                }
            }
            .frame(height: width)
            .contentShape(Rectangle())
    }
}

extension View {
    func squareHitbox() -> some View {
        modifier(SquareHitbox())
    }
}
