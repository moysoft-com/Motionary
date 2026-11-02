import SwiftUI
import UIKit

struct AppIconPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedIcon = AppIconPickerView.displayIconName(UIApplication.shared.alternateIconName)
    @State private var isChanging = false
    @State private var errorMessage: String?
    @State private var simulatorConfirmationUnavailable = false

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
                                    Text(icon == "MotionaryBW" ? "Light" : "Blue")
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
                    Text(UIApplication.shared.supportsAlternateIcons
                        ? "Choose the icon shown on your Home Screen."
                        : "Changing app icons isn’t supported on this device.")
                    .accessibilityIdentifier(simulatorConfirmationUnavailable
                        ? "app-icon-simulator-confirmation-unavailable" : "app-icon-picker-help")
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

    private static func displayIconName(_ systemName: String?) -> String {
        systemName == "MotionaryWBFallback" ? "MotionaryWB" : (systemName ?? "MotionaryBW")
    }

    @MainActor
    private func select(_ icon: String) async {
        guard !isChanging, selectedIcon != icon else { return }
        isChanging = true
        defer { isChanging = false }
        // Explicit PNGs are required for reliable alternate-icon switching
        // on older supported systems, including iPad-specific icon sizes.
        let systemName: String? = icon == "MotionaryBW" ? nil : "MotionaryWBFallback"
        do {
            try await UIApplication.shared.setAlternateIconName(systemName)
            selectedIcon = Self.displayIconName(UIApplication.shared.alternateIconName)
        } catch {
            // LaunchServices can apply the icon and then fail its confirmation
            // dialog (notably in Simulator). Reconcile the authoritative state
            // before reporting a failure for an operation that already succeeded.
            await Task.yield()
            let actualName = UIApplication.shared.alternateIconName
            selectedIcon = Self.displayIconName(actualName)
            #if targetEnvironment(simulator)
                let diagnostic = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? ""
                if diagnostic.contains("couldn't load upcall bundle principal class") {
                    simulatorConfirmationUnavailable = true
                }
            #endif
            if actualName == systemName {
                AppLogger.lifecycle.notice("Icon changed; system confirmation failed: \(String(reflecting: error as NSError), privacy: .public)")
                return
            }
            AppLogger.lifecycle.error("Failed to change app icon: \(String(reflecting: error as NSError), privacy: .public)")
            errorMessage = "The icon couldn’t be updated. Try again after returning to the Home Screen."
        }
    }
}

#Preview {
    AppIconPickerView()
}
