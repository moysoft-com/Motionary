import SwiftUI
import UIKit

struct SuggestionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let suggestion: Suggestion
    let viewModel: SuggestionsViewModel

    @State private var hapticTrigger = false
    @State private var copyHapticTrigger = false
    @State private var presentedSheet: SuggestionDetailSheet?
    @State private var isBlockConfirmationPresented = false
    @State private var reportResult: ReportResult?

    private var currentSuggestion: Suggestion {
        viewModel.suggestions.first(where: { $0.id == suggestion.id }) ?? suggestion
    }

    private var isVoted: Bool {
        viewModel.isVoted(currentSuggestion)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        if currentSuggestion.resolvedStatus != .normal {
                            SuggestionStatusBadge(status: currentSuggestion.resolvedStatus)
                        }

                        Text(currentSuggestion.title)
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(MotionaryTheme.textPrimary)

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Message")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(MotionaryTheme.textSecondary)
                                .textCase(.uppercase)

                            Text(currentSuggestion.description)
                                .font(.body)
                                .foregroundStyle(MotionaryTheme.textSecondary)
                                .textSelection(.enabled)
                        }

                        Divider()

                        SuggestionMetadataFooter(
                            suggestion: currentSuggestion,
                            onCopy: copyToPasteboard
                        )

                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .motionaryGlass(cornerRadius: 24)

                    Button {
                        hapticTrigger.toggle()
                        viewModel.toggleVote(for: currentSuggestion)
                    } label: {
                        HStack {
                            Label {
                                Text(isVoted ? "Voted" : "Upvote")
                            } icon: {
                                Image(systemName: isVoted ? "arrowtriangle.up.fill" : "arrowtriangle.up")
                            }
                            Spacer()
                            Text("\(currentSuggestion.votes)")
                                .contentTransition(.numericText())
                        }
                        .font(.headline)
                        .padding(14)
                        .foregroundStyle(isVoted ? Color.black : MotionaryTheme.accent)
                        .background(
                            isVoted ? MotionaryTheme.accent : Color.primary.opacity(0.07),
                            in: .rect(cornerRadius: 16, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .animation(.snappy, value: isVoted)
                    .sensoryFeedback(.impact(weight: .medium), trigger: hapticTrigger)
                }
                .padding(18)
            }
            .sensoryFeedback(.success, trigger: copyHapticTrigger)
            .background { MotionaryTheme.background(for: colorScheme).ignoresSafeArea() }
            .navigationTitle("Suggestion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if currentSuggestion.ownerID != viewModel.currentUserID {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            presentedSheet = .actions
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("More options")
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case .actions:
                    SuggestionActionsView(
                        onReport: { presentedSheet = .report },
                        onBlock: {
                            presentedSheet = nil
                            isBlockConfirmationPresented = true
                        }
                    )
                case .report:
                    ReportSuggestionView { reason, details in
                        submitReport(reason, details: details)
                    }
                }
            }
            .confirmationDialog("Block this user?", isPresented: $isBlockConfirmationPresented, titleVisibility: .visible) {
                Button("Block User", role: .destructive) {
                    viewModel.blockOwner(of: currentSuggestion)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All suggestions from this user will be hidden on this device. You can undo this from the suggestions sort menu.")
            }
            .alert(item: $reportResult) { result in
                Alert(
                    title: Text(result.succeeded ? "Report Submitted" : "Couldn’t Submit Report"),
                    message: Text(
                        result.succeeded
                            ? "Thanks. We’ll review this suggestion."
                            : "Please try again later."
                    ),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private func submitReport(_ reason: SuggestionReportReason, details: String) {
        viewModel.reportSuggestion(currentSuggestion, reason: reason, details: details) { succeeded in
            reportResult = ReportResult(succeeded: succeeded)
        }
    }

    private func copyToPasteboard(_ value: String) {
        UIPasteboard.general.string = value
        copyHapticTrigger.toggle()
    }
}

private struct SuggestionMetadataFooter: View {
    let suggestion: Suggestion
    let onCopy: (String) -> Void

    private var suggestionID: String {
        suggestion.id ?? "Unavailable"
    }

    private var authorID: String {
        suggestion.ownerID ?? "Unknown"
    }

    private var publishedText: String {
        guard let date = suggestion.createdAt?.dateValue() else { return "Publish date unavailable" }
        return "Published \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var compactAuthorID: String {
        guard authorID.count > 12 else { return authorID }
        return "\(authorID.prefix(5))…\(authorID.suffix(5))"
    }

    var body: some View {
        HStack(spacing: 10) {
            Label(publishedText, systemImage: "calendar")
                .lineLimit(1)

            Spacer(minLength: 8)

            Menu {
                Section("Author ID") {
                    Text(authorID)
                    if suggestion.ownerID != nil {
                        Button("Copy Author ID", systemImage: "doc.on.doc") {
                            onCopy(authorID)
                        }
                    }
                }

                Section("Suggestion ID") {
                    Text(suggestionID)
                    if suggestion.id != nil {
                        Button("Copy Suggestion ID", systemImage: "doc.on.doc") {
                            onCopy(suggestionID)
                        }
                    }
                }
            } label: {
                Label(compactAuthorID, systemImage: "person.crop.circle")
                    .fontDesign(.monospaced)
                    .lineLimit(1)
            }
            .accessibilityLabel("Suggestion metadata")
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(MotionaryTheme.textSecondary)
    }
}

private enum SuggestionDetailSheet: String, Identifiable {
    case actions
    case report
    var id: String { rawValue }
}

private struct SuggestionActionsView: View {
    @Environment(\.dismiss) private var dismiss
    let onReport: () -> Void
    let onBlock: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button("Report Suggestion", systemImage: "exclamationmark.bubble") {
                    dismiss()
                    DispatchQueue.main.async { onReport() }
                }
                Button("Block User", systemImage: "person.crop.circle.badge.xmark", role: .destructive) {
                    onBlock()
                }
            }
            .navigationTitle("More Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct ReportSuggestionView: View {
    @Environment(\.dismiss) private var dismiss
    let onSubmit: (SuggestionReportReason, String) -> Void

    @State private var reason: SuggestionReportReason = .spam
    @State private var details = ""

    private var requiresDetails: Bool {
        reason == .illegal || reason == .other
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Reason", selection: $reason) {
                    ForEach(SuggestionReportReason.allCases) { reason in
                        Text(reason.title).tag(reason)
                    }
                }

                Section {
                    TextField("Explain what is wrong", text: $details, axis: .vertical)
                        .lineLimit(4...8)
                } header: {
                    Text("Details")
                } footer: {
                    Text(requiresDetails ? "Details are required for this report." : "Optional. Do not include unnecessary personal information.")
                }

                Section {
                    Link("Formal illegal-content notice", destination: URL(string: "https://moysoft.com/en/community#illegal-content-notice")!)
                } footer: {
                    Text("Use the formal notice form when you believe content violates the law.")
                }
            }
            .navigationTitle("Report Suggestion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        onSubmit(reason, details.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(requiresDetails && details.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
                }
            }
        }
    }
}

private struct ReportResult: Identifiable {
    let id = UUID()
    let succeeded: Bool
}
