// User-configurable export settings.

import SwiftUI
import UIKit

struct ExportSettingsView: View {
    let project: EditorProject
    let onExport: (VideoExportSettings) -> Void
    let onSettingsChanged: (VideoExportSettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var settings: VideoExportSettings
    @State private var resolutionPreset: ExportResolutionPreset
    @State private var showAdvanced: Bool = false

    init(
        project: EditorProject,
        onSettingsChanged: @escaping (VideoExportSettings) -> Void = { _ in },
        onExport: @escaping (VideoExportSettings) -> Void
    ) {
        self.project = project
        self.onExport = onExport
        self.onSettingsChanged = onSettingsChanged
        var initialSettings = project.exportSettings ?? VideoExportSettings.recommended(for: project)
        if project.exportSettings == nil {
            let storedDefaults = UserDefaults.standard
            let quality = ExportQuality(
                rawValue: storedDefaults.string(forKey: AppPreferences.exportQualityKey)
                    ?? AppPreferences.defaultExportQuality
            ) ?? .balanced
            initialSettings.videoBitrate = Int(
                Double(initialSettings.videoBitrate) * quality.bitrateMultiplier
            )
            initialSettings.codec = ExportVideoCodec(
                rawValue: storedDefaults.string(forKey: AppPreferences.exportCodecKey)
                    ?? AppPreferences.defaultExportCodec
            ) ?? .h264
            initialSettings.container = ExportContainer(
                rawValue: storedDefaults.string(forKey: AppPreferences.exportContainerKey)
                    ?? AppPreferences.defaultExportContainer
            ) ?? .mp4
        }
        _settings = State(initialValue: initialSettings.normalized)
        _resolutionPreset = State(
            initialValue: Self.resolutionPreset(for: initialSettings, project: project)
        )
    }

    var body: some View {
        NavigationStack {
            VStack {
                Form {
                    VStack(alignment: .leading) {
                        Text("Resolution")
                        Picker("Preset", selection: $resolutionPreset) {
                            ForEach(ExportResolutionPreset.allCases.dropLast()) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: resolutionPreset) { _, preset in
                            applyResolutionPreset(preset)
                        }
                    }
                    VStack(alignment: .leading) {
                        Picker("Frame rate", selection: $settings.frameRate) {
                            ForEach(availableFrameRates, id: \.self) { value in
                                Text("\(value) fps").tag(Int32(value))
                            }
                        }
                        .pickerStyle(.menu)
                        if settings.frameRate > 60 {
                            Text("Photos may play high-frame-rate videos in slow motion. Choose 1× playback in Photos, or export the original to Files.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    //                    HStack {
                    //                        TextField("Width", value: dimensionBinding(\.width), format: .number)
                    //                            .keyboardType(.numberPad)
                    //                        Text("×")
                    //                            .foregroundStyle(.secondary)
                    //                        TextField("Height", value: dimensionBinding(\.height), format: .number)
                    //                            .keyboardType(.numberPad)
                    //                    }
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        Picker("Codec", selection: $settings.codec) {
                            ForEach(ExportVideoCodec.allCases) { codec in
                                Text(codec.title).tag(codec)
                            }
                        }
                        
                        Picker("Format", selection: $settings.container) {
                            ForEach(ExportContainer.allCases) { container in
                                Text(container.title).tag(container)
                            }
                        }
                        
                        EditorValueScrubber(
                            title: "Video bitrate",
                            systemImage: "speedometer",
                            value: videoBitrateMbps,
                            range: 1...80,
                            step: 0.5,
                            format: { String(format: "%.1f Mbit/s", $0) },
                            onBegan: {},
                            onChanged: { settings.videoBitrate = Int($0 * 1_000_000) },
                            onEnded: {}
                        )
                        
                        Picker("Audio bitrate", selection: $settings.audioBitrate) {
                            ForEach([96_000, 128_000, 192_000, 256_000, 320_000], id: \.self) { bitrate in
                                Text("\(bitrate / 1_000) kbit/s").tag(bitrate)
                            }
                        }
                    }
                }

//                Section("Frame rate") {
//                    Picker("FPS", selection: $settings.frameRate) {
//                        ForEach([24, 25, 30, 50, 60], id: \.self) { value in
//                            Text("\(value) fps").tag(Int32(value))
//                        }
//                    }
//                    .pickerStyle(.segmented)
//                }



                Text("Estimated size: \(estimatedSize)")
                    .monospacedDigit()
                    .font(.caption)
                    .opacity(0.5)
            }
            .scrollContentBackground(.hidden)
            .background { MotionaryTheme.background(for: colorScheme).opacity(0.75).ignoresSafeArea() }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        onExport(settings.normalized)
                    }
                    .fontWeight(.semibold)
                    .disabled(settings.width < 2 || settings.height < 2)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: settings) { _, value in
            onSettingsChanged(value.normalized)
        }
    }

    private var videoBitrateMbps: Double {
        Double(settings.videoBitrate) / 1_000_000
    }

    private var availableFrameRates: [Int] {
        let base = [24, 25, 30, 50, 60]
        return UIScreen.main.maximumFramesPerSecond >= 120 || settings.frameRate == 120
            ? base + [120]
            : base
    }

    private static func resolutionPreset(
        for settings: VideoExportSettings,
        project: EditorProject
    ) -> ExportResolutionPreset {
        if settings.width == project.renderSettings.width,
            settings.height == project.renderSettings.height
        {
            return .project
        }
        return switch max(settings.width, settings.height) {
        case 1280: .hd
        case 1920: .fullHD
        case 3840: .uhd
        default: .custom
        }
    }

    private func dimensionBinding(_ keyPath: WritableKeyPath<VideoExportSettings, Int>) -> Binding<Int> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: {
                settings[keyPath: keyPath] = $0
                resolutionPreset = .custom
            }
        )
    }

    private var estimatedSize: String {
        let bitsPerSecond = Double(settings.videoBitrate + settings.audioBitrate)
        let megabytes = bitsPerSecond * max(project.duration, 0) / 8 / 1_000_000
        return String(format: "~%.1f MB", megabytes)
    }

    private func applyResolutionPreset(_ preset: ExportResolutionPreset) {
        guard preset != .custom else { return }
        if preset == .project {
            settings.width = project.renderSettings.width
            settings.height = project.renderSettings.height
            return
        }

        let sourceWidth = max(project.renderSettings.width, 1)
        let sourceHeight = max(project.renderSettings.height, 1)
        let isLandscape = sourceWidth >= sourceHeight
        let longEdge = preset.longEdge
        let aspect = Double(sourceWidth) / Double(sourceHeight)
        let shortEdge: Int
        if isLandscape {
            shortEdge = Int((Double(longEdge) / aspect).rounded())
            settings.width = longEdge
            settings.height = shortEdge
        } else {
            shortEdge = Int((Double(longEdge) * aspect).rounded())
            settings.width = shortEdge
            settings.height = longEdge
        }
        settings = settings.normalized
    }
}

private enum ExportResolutionPreset: String, CaseIterable, Identifiable {
    case project
    case hd
    case fullHD
    case uhd
    case custom
    
    var id: String { rawValue }

    var title: String {
        switch self {
        case .project: "Project"
        case .uhd: "4K"
        case .fullHD: "1080p"
        case .hd: "720p"
        case .custom: "Custom"
        }
    }

    var longEdge: Int {
        switch self {
        case .uhd: 3840
        case .fullHD: 1920
        case .hd: 1280
        case .project, .custom: 0
        }
    }
}
