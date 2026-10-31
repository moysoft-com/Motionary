import SwiftUI
import UIKit

struct AppIconPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedIcon = UIApplication.shared.alternateIconName ?? "MotionaryBW"
    @State private var isChanging = false
    @State private var errorMessage: String?

    private let icons = ["MotionaryBW", "MotionaryWB"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(icons, id: \.self) { icon in
                        Button {
                            Task { await select(icon) }
                        } label: {
                            HStack(spacing: MotionaryDesign.Spacing.xxl) {
                                Image("\(icon)Preview")
                                    .resizable()
                                    .interpolation(.high)
                                    .antialiased(true)
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: MotionaryDesign.Radius.graph, style: .continuous))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(icon)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(MotionaryTheme.textPrimary)
                                    if icon == "MotionaryBW" {
                                        Text("Default")
                                            .font(.caption)
                                            .foregroundStyle(MotionaryTheme.textSecondary)
                                    }
                                }
                                Spacer()
                                if selectedIcon == icon {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(MotionaryTheme.accent)
                                }
                            }
                            .padding(.vertical, MotionaryDesign.Spacing.xs)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("app-icon-\(icon)")
                        .accessibilityValue(selectedIcon == icon ? "Selected" : "Not selected")
                        .accessibilityAddTraits(selectedIcon == icon ? [.isSelected] : [])
                        .disabled(isChanging || !UIApplication.shared.supportsAlternateIcons)
                    }
                } footer: {
                    Text("Choose the icon shown on your Home Screen.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background { MotionaryTheme.background(for: colorScheme).opacity(0.75).ignoresSafeArea() }
            .navigationTitle("App Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .overlay {
                if isChanging {
                    ProgressView()
                        .tint(MotionaryTheme.accent)
                        .padding(MotionaryDesign.Spacing.xxl)
                        .motionaryGlass(cornerRadius: MotionaryDesign.Radius.panel)
                }
            }
            .alert("Couldn’t Change Icon", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @MainActor
    private func select(_ icon: String) async {
        guard !isChanging, selectedIcon != icon else { return }
        isChanging = true
        defer { isChanging = false }
        do {
            try await UIApplication.shared.setAlternateIconName(icon == "MotionaryBW" ? nil : icon)
            selectedIcon = UIApplication.shared.alternateIconName ?? "MotionaryBW"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    AppIconPickerView()
}
