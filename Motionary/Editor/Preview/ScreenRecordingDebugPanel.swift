import SwiftUI

struct ScreenRecordingDebugPanel: View {
    #if MOTIONARY_SCREEN_REC_PERFORMANCE
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif

    private enum Activation: String {
        case off
        case capture
        case always
    }

    let viewModel: EditorViewModel

    @Environment(\.isSceneCaptured) private var isCaptured
    @AppStorage("screenRecordingDebug.freezeScrub") private var freezesPreview = false
    @AppStorage("screenRecordingDebug.hideOverlays") private var hidesOverlays = false
    @AppStorage("screenRecordingDebug.activation") private var activation: Activation = .off
    @AppStorage("screenRecordingDebug.effectDimension") private var effectDimension = 540
    @AppStorage("screenRecordingDebug.scrubFPS") private var scrubFPS = 30
    @State private var isExpanded = false

    private var modeIsActive: Bool {
        activation == .always || (activation == .capture && isCaptured)
    }

    private var configuration: ScreenRecordingPreviewConfiguration {
        ScreenRecordingPreviewConfiguration(
            freezesScrubPreview: freezesPreview,
            hidesCanvasOverlays: hidesOverlays,
            effectDimension: modeIsActive && effectDimension > 0 ? effectDimension : nil,
            scrubFrameRateLimit: modeIsActive && scrubFPS > 0 ? scrubFPS : nil
        )
    }

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "waveform.path.ecg")
                Text("Rec Perf")
                if isCaptured {
                    Circle()
                        .fill(.red)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground).opacity(0.94), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Screen recording performance")
        .accessibilityValue(isCaptured ? Text("Capture detected") : Text("No capture detected"))
        .accessibilityIdentifier("screen-recording-debug-panel")
        .popover(isPresented: $isExpanded, arrowEdge: .top) {
            controls
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: configuration, initial: true) { _, configuration in
            viewModel.configureScreenRecordingPreview(configuration)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Screen Recording")
                    .font(.headline)
                Spacer()
                Button("Done") { isExpanded = false }
                    .font(.subheadline.weight(.semibold))
            }
            Text(isCaptured ? "Capture detected" : "No capture detected")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Freeze preview while scrubbing", isOn: $freezesPreview)
                .accessibilityIdentifier("screen-recording-freeze-scrub")
            Toggle("Hide canvas overlays", isOn: $hidesOverlays)
                .accessibilityIdentifier("screen-recording-hide-overlays")

            Divider()

            Picker("Recording mode", selection: $activation) {
                Text("Off").tag(Activation.off)
                Text("During capture").tag(Activation.capture)
                Text("Always").tag(Activation.always)
            }
            .accessibilityIdentifier("screen-recording-mode")

            Picker("Effect raster", selection: $effectDimension) {
                Text("Normal").tag(0)
                Text("720 px").tag(720)
                Text("540 px").tag(540)
                Text("360 px").tag(360)
            }
            .accessibilityIdentifier("screen-recording-effect-raster")

            Picker("Scrub preview rate", selection: $scrubFPS) {
                Text("Device").tag(0)
                Text("60 FPS").tag(60)
                Text("30 FPS").tag(30)
            }
            .accessibilityIdentifier("screen-recording-scrub-rate")
        }
        .font(.subheadline)
        .pickerStyle(.menu)
        .padding(16)
        .frame(idealWidth: 304)
    }
}
