import SwiftUI

struct SuggestionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let suggestion: Suggestion
    let viewModel: SuggestionsViewModel

    @State private var hapticTrigger = false
    @State private var isReportDialogPresented = false
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

                        Text(currentSuggestion.description)
                            .font(.body)
                            .foregroundStyle(MotionaryTheme.textSecondary)
                            .textSelection(.enabled)
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
            .background { MotionaryTheme.background(for: colorScheme).ignoresSafeArea() }
            .navigationTitle("Suggestion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if currentSuggestion.ownerID != viewModel.currentUserID {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isReportDialogPresented = true
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
            .confirmationDialog(
                "Report Suggestion",
                isPresented: $isReportDialogPresented,
                titleVisibility: .visible
            ) {
                ForEach(SuggestionReportReason.allCases) { reason in
                    Button(reason.title) {
                        submitReport(reason)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose the reason that best describes the problem.")
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

    private func submitReport(_ reason: SuggestionReportReason) {
        viewModel.reportSuggestion(currentSuggestion, reason: reason) { succeeded in
            reportResult = ReportResult(succeeded: succeeded)
        }
    }
}

private struct ReportResult: Identifiable {
    let id = UUID()
    let succeeded: Bool
}
