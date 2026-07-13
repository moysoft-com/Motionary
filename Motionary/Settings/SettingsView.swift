// App-wide preferences, permissions shortcuts, and product information.

import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(AppPreferences.appearanceKey)
    private var appearance = AppPreferences.defaultAppearance
    @AppStorage(AppPreferences.newProjectFrameRateKey)
    private var newProjectFrameRate = AppPreferences.defaultFrameRate
    @AppStorage(AppPreferences.exportQualityKey)
    private var exportQuality = AppPreferences.defaultExportQuality
    @AppStorage(AppPreferences.exportCodecKey)
    private var exportCodec = AppPreferences.defaultExportCodec
    @AppStorage(AppPreferences.exportContainerKey)
    private var exportContainer = AppPreferences.defaultExportContainer

    @State private var isResetConfirmationPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $newProjectFrameRate) {
                        ForEach([24, 25, 30, 50, 60], id: \.self) { frameRate in
                            Text("\(frameRate) fps").tag(frameRate)
                        }
                    } label: {
                        SettingsLabel(
                            "Frame rate",
                            systemImage: "speedometer",
                            colors: [.cyan]
                        )
                    }
                } header: {
                    Text("New projects")
                }

                Section {
                    Picker(selection: $exportQuality) {
                        ForEach(ExportQuality.allCases) { quality in
                            Text(quality.title).tag(quality.rawValue)
                        }
                    } label: {
                        SettingsLabel(
                            "Quality",
                            systemImage: "slider.horizontal.3",
                            colors: [.pink]
                        )
                    }

                    Picker(selection: $exportCodec) {
                        ForEach(ExportVideoCodec.allCases) { codec in
                            Text(codec.title).tag(codec.rawValue)
                        }
                    } label: {
                        SettingsLabel(
                            "Video codec",
                            systemImage: "film",
                            colors: [.pink]
                        )
                    }

                    Picker(selection: $exportContainer) {
                        ForEach(ExportContainer.allCases) { container in
                            Text(container.title).tag(container.rawValue)
                        }
                    } label: {
                        SettingsLabel(
                            "File format",
                            systemImage: "document.badge.gearshape",
                            colors: [.pink]
                        )
                    }
                } header: {
                    Text("Export defaults")
                }

                Section {
                    NavigationLink {
                        SuggestionsListView()
                    } label: {
                        SettingsLabel("Suggestions", systemImage: "sparkles", colors: [.yellow, .orange])
                    }
                } header: {
                    Text("Other")
                }

                Section {
                    HStack {
                        SettingsLabel("Version", systemImage: "info", colors: [.gray])
                        Spacer(minLength: 12)
                        Text(versionDescription)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Link(destination: URL(string: "https://moysoft.com/privacy")!) {
                            SettingsLabel("Privacy", systemImage: "hand.raised.fill", colors: [.blue])
                        }
                        Spacer()
                        Image(systemName: "arrow.up.forward")
                    }
                    HStack {
                        Link(destination: URL(string: "https://moysoft.com/imprint")!) {
                            SettingsLabel("Imprint", systemImage: "doc.text.fill", colors: [.blue])
                        }
                        Spacer()
                        Image(systemName: "arrow.up.forward")
                    }
                    HStack {
                        Link(destination: URL(string: "https://moysoft.com/")!) {
                            Image("moysoftfull")
                                .resizable()
                                .interpolation(.high)
                                .antialiased(true)
                                .scaledToFit()
                                .frame(height: 22)
                                .clipShape(.rect(cornerRadius: 7, style: .continuous))
                        }
                        Spacer()
                        Image(systemName: "arrow.up.forward")
                    }
                } header: {
                    Text("About")
                }

                Section {
                    Button(role: .destructive) {
                        isResetConfirmationPresented = true
                    } label: {
                        SettingsLabel("Reset Settings", systemImage: "arrow.counterclockwise", colors: [.red, .orange])
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background { MotionaryTheme.background(for: colorScheme).ignoresSafeArea() }
            .safeAreaBar(edge: .top) {
                HStack(spacing: 7) {
                    Text("Settings")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(MotionaryTheme.textPrimary)
                    Spacer()
                }
                .padding(18)
            }
            .tint(MotionaryTheme.accent)
            .confirmationDialog(
                "Reset all settings?",
                isPresented: $isResetConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Reset Settings", role: .destructive) {
                    resetSettings()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your projects and media will not be deleted.")
            }
        }
        .labelStyle(.titleAndIcon)
    }

    private var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func resetSettings() {
        AppPreferences.reset()
        appearance = AppPreferences.defaultAppearance
        newProjectFrameRate = AppPreferences.defaultFrameRate
        exportQuality = AppPreferences.defaultExportQuality
        exportCodec = AppPreferences.defaultExportCodec
        exportContainer = AppPreferences.defaultExportContainer
    }
}

private struct SettingsLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let colors: [Color]

    init(_ title: LocalizedStringKey, systemImage: String, colors: [Color]) {
        self.title = title
        self.systemImage = systemImage
        self.colors = colors
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                .foregroundStyle(
                    colors.first ?? .white
                )
                .frame(width: 22, height: 22)
                .clipShape(.rect(cornerRadius: 7, style: .continuous))
                .shadow(color: colors.first?.opacity(0.18) ?? .clear, radius: 2, y: 1)
        }
    }
}

#Preview {
    SettingsView()
}
