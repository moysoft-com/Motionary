// Suggestion composer.

import SwiftUI

struct AddSuggestionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let viewModel: SuggestionsViewModel

    @State private var title = ""
    @State private var description = ""
    @State private var acceptsCommunityStandards = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case title
        case description
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        (4...100).contains(trimmedTitle.count)
            && (10...2_000).contains(trimmedDescription.count)
            && acceptsCommunityStandards
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("A short, clear title", text: $title)
                        .focused($focusedField, equals: .title)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .description }
                } header: {
                    Text("Title")
                } footer: {
                    Text("4–100 characters. Make it easy to understand at a glance.")
                }

                Section {
                    TextField(
                        "Describe the idea and why it would be useful",
                        text: $description,
                        axis: .vertical
                    )
                    .focused($focusedField, equals: .description)
                    .lineLimit(5...9)
                } header: {
                    Text("Details")
                } footer: {
                    Text("10–2,000 characters. Your suggestion will be visible to everyone using Motionary.")
                }

                Section {
                    Toggle("I agree to the Community Standards", isOn: $acceptsCommunityStandards)
                    Link("Read Community Standards", destination: SuggestionContentPolicy.communityURL)
                } footer: {
                    Text("Do not submit personal data, harassment, hate, sexual content, threats, illegal content, or spam.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background { MotionaryTheme.background(for: colorScheme).ignoresSafeArea() }
            .navigationTitle("New Suggestion")
            .navigationBarTitleDisplayMode(.inline)
            .tint(MotionaryTheme.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        viewModel.addSuggestion(
                            title: trimmedTitle,
                            description: trimmedDescription
                        )
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSubmit)
                }
            }
            .task {
                focusedField = .title
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
