// User-configurable export settings.

import SwiftUI

struct ExportSettingsView: View {
    let project: EditorProject
    let onExport: (VideoExportSettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var settings: VideoExportSettings
    @State private var resolutionPreset: ExportResolutionPreset = .project
    @State private var showAdvanced: Bool = false

    init(project: EditorProject, onExport: @escaping (VideoExportSettings) -> Void) {
        self.project = project
        self.onExport = onExport
        var defaults = VideoExportSettings.recommended(for: project)
        let storedDefaults = UserDefaults.standard
        let quality = ExportQuality(
            rawValue: storedDefaults.string(forKey: AppPreferences.exportQualityKey)
                ?? AppPreferences.defaultExportQuality
        ) ?? .balanced
        defaults.videoBitrate = Int(Double(defaults.videoBitrate) * quality.bitrateMultiplier)
        defaults.codec = ExportVideoCodec(
            rawValue: storedDefaults.string(forKey: AppPreferences.exportCodecKey)
                ?? AppPreferences.defaultExportCodec
        ) ?? .h264
        defaults.container = ExportContainer(
            rawValue: storedDefaults.string(forKey: AppPreferences.exportContainerKey)
                ?? AppPreferences.defaultExportContainer
        ) ?? .mp4
        _settings = State(initialValue: defaults.normalized)
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
                        Text("Frame rate")
                        Picker("FPS", selection: $settings.frameRate) {
                            ForEach([24, 25, 30, 50, 60], id: \.self) { value in
                                Text("\(value) fps").tag(Int32(value))
                            }
                        }
                        .pickerStyle(.segmented)
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
                        
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Video bitrate") {
                                Text("\(videoBitrateMbps, specifier: "%.1f") Mbit/s")
                                    .monospacedDigit()
                            }
                            Slider(value: videoBitrateBinding, in: 1...80, step: 0.5)
                        }
                        
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
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onExport(settings.normalized)
                    }
                    .fontWeight(.semibold)
                    .disabled(settings.width < 2 || settings.height < 2)
                }
            }
        }
        .presentationDetents([.large])
    }

    private var videoBitrateMbps: Double {
        Double(settings.videoBitrate) / 1_000_000
    }

    private var videoBitrateBinding: Binding<Double> {
        Binding(
            get: { videoBitrateMbps },
            set: { settings.videoBitrate = Int($0 * 1_000_000) }
        )
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
