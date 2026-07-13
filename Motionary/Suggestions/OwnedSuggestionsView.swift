import SwiftUI

struct EditSuggestionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let suggestion: Suggestion
    let viewModel: SuggestionsViewModel

    @State private var title: String
    @State private var description: String

    init(suggestion: Suggestion, viewModel: SuggestionsViewModel) {
        self.suggestion = suggestion
        self.viewModel = viewModel
        _title = State(initialValue: suggestion.title)
        _description = State(initialValue: suggestion.description)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Suggestion title", text: $title)
                }
                Section("Details") {
                    TextField("Describe your suggestion", text: $description, axis: .vertical)
                        .lineLimit(5...9)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background { MotionaryTheme.background(for: colorScheme).ignoresSafeArea() }
            .navigationTitle("Edit Suggestion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.updateSuggestion(
                            suggestion,
                            title: trimmedTitle,
                            description: trimmedDescription
                        )
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(
                        !(4...100).contains(trimmedTitle.count)
                            || !(10...2_000).contains(trimmedDescription.count)
                    )
                }
            }
        }
    }
}
