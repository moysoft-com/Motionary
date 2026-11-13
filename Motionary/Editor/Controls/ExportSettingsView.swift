// User-configurable export settings.

import SwiftUI
import UIKit
import AVFoundation
import CoreImage
import QuartzCore
import CoreHaptics

struct ExportSettingsView: View {
    let project: EditorProject
    let onExport: (VideoExportSettings) -> Void
    let onSettingsChanged: (VideoExportSettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var settings: VideoExportSettings
    @State private var resolutionPreset: ExportResolutionPreset
    @State private var showAdvanced: Bool = false
    @State private var showWatermarkConfirmation = false

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
                    Toggle("Motionary watermark", isOn: Binding(
                        get: { settings.watermarkEnabled },
                        set: { enabled in
                            if enabled { settings.watermarkEnabled = true }
                            else { showWatermarkConfirmation = true }
                        }
                    ))
                    .tint(MotionaryTheme.accent)
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
        .background {
            WatermarkAlertAnimationOverlay(isPresented: showWatermarkConfirmation, colorScheme: colorScheme)
                .frame(width: 0, height: 0)
        }
        .alert("Remove watermark?", isPresented: $showWatermarkConfirmation) {
            Button("Keep Watermark", role: .cancel) {
                NotificationCenter.default.post(name: .watermarkAlertWillDismiss, object: nil)
            }
                .keyboardShortcut(.defaultAction)
                .tint(MotionaryTheme.accent)
            Button("Remove Watermark", role: .destructive) {
                NotificationCenter.default.post(name: .watermarkAlertWillDismiss, object: nil)
                settings.watermarkEnabled = false
            }
        } message: {
            Text("Every watermark helps more creators discover Motionary and grow our community :)")
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


private extension Notification.Name {
    static let watermarkAlertWillDismiss = Notification.Name("MotionaryWatermarkAlertWillDismiss")
}

// The native alert lives above SwiftUI sheets, so its decoration needs its own
// non-interactive window at alert level. The alert itself remains untouched.
private struct WatermarkAlertAnimationOverlay: UIViewRepresentable {
    let isPresented: Bool
    let colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.update(isPresented: isPresented, source: view, colorScheme: colorScheme)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.hide(immediately: true)
    }

    @MainActor
    final class Coordinator {
        private var overlayWindow: UIWindow?
        private var generation = 0
        private var presented = false
        private var colorScheme: ColorScheme = .light
        private var overlayState: RecommendedOverlayState?
        private let haptics = RecommendedHaptics()
        private var dismissObserver: NSObjectProtocol?

        func update(isPresented: Bool, source: UIView, colorScheme: ColorScheme) {
            self.colorScheme = colorScheme
            guard isPresented != presented else { return }
            presented = isPresented
            generation += 1
            if isPresented {
                haptics.playAfterDelay()
                locateButton(source: source, generation: generation, attempts: 0)
            } else {
                hide()
            }
        }

        func hide(immediately: Bool = false) {
            presented = false
            generation += 1
            haptics.stop()
            if let dismissObserver {
                NotificationCenter.default.removeObserver(dismissObserver)
                self.dismissObserver = nil
            }
            guard let window = overlayWindow else { return }
            overlayWindow = nil
            let state = overlayState
            overlayState = nil
            guard !immediately else {
                window.isHidden = true
                return
            }
            withAnimation(.easeIn(duration: 0.16)) { state?.isDismissing = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
                window.isHidden = true
            }
        }

        private func locateButton(source: UIView, generation: Int, attempts: Int) {
            guard presented, self.generation == generation else { return }
            if let scene = source.window?.windowScene,
               let alertWindow = scene.windows.first(where: { window in
                   window !== self.overlayWindow && self.findKeepLabel(in: window) != nil
               }), let label = findKeepLabel(in: alertWindow) {
                show(in: scene, label: label)
                return
            }
            guard attempts < 60 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak source] in
                guard let self, let source else { return }
                self.locateButton(source: source, generation: generation, attempts: attempts + 1)
            }
        }

        private func findKeepLabel(in view: UIView) -> UILabel? {
            if let label = view as? UILabel, label.text == "Keep Watermark" { return label }
            for child in view.subviews {
                if let label = findKeepLabel(in: child) { return label }
            }
            return nil
        }

        private func show(in scene: UIWindowScene, label: UILabel) {
            // Position relative to the native button without intercepting touches.
            var ancestor = label.superview
            var control: UIControl?
            while let view = ancestor, view.bounds.width < 320 {
                if let candidate = view as? UIControl { control = candidate; break }
                ancestor = view.superview
            }
            let target = control ?? label
            let targetFrame = target.convert(target.bounds, to: nil)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.windowLevel = .alert + 1
            window.backgroundColor = .clear
            window.isUserInteractionEnabled = false
            let state = RecommendedOverlayState()
            overlayState = state
            let host = UIHostingController(rootView:
                RecommendedAnimationView(useDarkInk: colorScheme == .light, state: state)
                    .allowsHitTesting(false).accessibilityHidden(true)
            )
            host.view.backgroundColor = .clear
            let root = UIViewController()
            root.view.backgroundColor = .clear
            root.addChild(host)
            root.view.addSubview(host.view)
            host.didMove(toParent: root)
            host.view.frame = CGRect(x: max(8, targetFrame.minX - 40), y: targetFrame.minY + 23, width: 180, height: 120)
            window.rootViewController = root
            overlayWindow = window
            window.isHidden = false
            dismissObserver = NotificationCenter.default.addObserver(
                forName: .watermarkAlertWillDismiss, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }
}

// Core Haptics setup can block; serialize it away from the UI and cancel pending
// playback when the native alert disappears.
private final class RecommendedHaptics: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.motionary.recommended-haptics", qos: .userInitiated)
    private var engine: CHHapticEngine?
    private var generation = 0

    func playAfterDelay() {
        queue.async {
            self.generation += 1
            let currentGeneration = self.generation
            guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
            do {
                let engine = try CHHapticEngine()
                try engine.start()
                let pulseCount = 28
                let events = (0..<pulseCount).map { index in
                    let progress = Double(index) / Double(pulseCount - 1)
                    let envelope = pow(sin(.pi * progress), 2)
                    return CHHapticEvent(eventType: .hapticTransient, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(0.42 * envelope)),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2)
                    ], relativeTime: Double(index) * 0.075)
                }
                let pattern = try CHHapticPattern(events: events, parameters: [])
                let player = try engine.makePlayer(with: pattern)
                self.engine = engine
                self.queue.asyncAfter(deadline: .now()) {
                    guard self.generation == currentGeneration else { return }
                    try? player.start(atTime: CHHapticTimeImmediate)
                }
            } catch {
                // Haptics are optional; the alert and animation remain usable.
            }
        }
    }

    func stop() {
        queue.async {
            self.generation += 1
            self.engine?.stop(completionHandler: nil)
            self.engine = nil
        }
    }

}

@MainActor
private final class RecommendedOverlayState: ObservableObject {
    @Published var isDismissing = false
}

// Render frames with transparent black and ink adapted to the appearance.
private struct RecommendedAnimationView: View {
    @StateObject private var playback: RecommendedAnimationPlayback
    @ObservedObject var state: RecommendedOverlayState
    private let useDarkInk: Bool

    init(useDarkInk: Bool, state: RecommendedOverlayState) {
        _playback = StateObject(wrappedValue: RecommendedAnimationPlayback(useDarkInk: useDarkInk))
        self.state = state
        self.useDarkInk = useDarkInk
    }

    var body: some View {
        Group {
            if let frame = playback.frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .shadow(color: (useDarkInk ? Color.white : Color.black).opacity(useDarkInk ? 1 : 0.7), radius: useDarkInk ? 4 : 3, x: 0, y: 1)
        .shadow(color: useDarkInk ? Color.white.opacity(0.9) : .clear, radius: 1, x: 0, y: 0)
        .scaleEffect(state.isDismissing ? 0.88 : 1)
        .opacity(state.isDismissing ? 0 : 1)
        .blur(radius: state.isDismissing ? 6 : 0)
        .onAppear { playback.start() }
        .onDisappear { playback.stop() }
    }
}

// AVPlayerItemVideoOutput hands ownership of each immutable frame to the caller.
private struct RecommendedFrameBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

@MainActor
private final class RecommendedAnimationPlayback: NSObject, ObservableObject {
    @Published var frame: CGImage?
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let useDarkInk: Bool
    private let renderQueue = DispatchQueue(label: "com.motionary.recommended-animation", qos: .userInteractive)
    private var isRendering = false
    private var playbackGeneration = 0

    init(useDarkInk: Bool) {
        self.useDarkInk = useDarkInk
        super.init()
    }

    func start() {
        guard player == nil,
              let url = Bundle.main.url(forResource: "RecommendedAnimation", withExtension: "mp4") else { return }
        playbackGeneration += 1
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        self.output = output
        self.player = player
        player.play()
        let displayLink = CADisplayLink(target: self, selector: #selector(updateFrame))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    @objc private func updateFrame(_ displayLink: CADisplayLink) {
        guard let output, !isRendering else { return }
        let time = output.itemTime(forHostTime: displayLink.targetTimestamp)
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        let shouldFreeze = CMTimeGetSeconds(time) >= 5
        if shouldFreeze {
            player?.pause()
            displayLink.invalidate()
            self.displayLink = nil
        }
        isRendering = true
        let generation = playbackGeneration
        let context = context
        let useDarkInk = useDarkInk
        let frameBuffer = RecommendedFrameBuffer(value: buffer)
        renderQueue.async { [weak self] in
            let rendered: CGImage? = autoreleasepool {
                let image = CIImage(cvPixelBuffer: frameBuffer.value)
                let scale = 540 / image.extent.width
                let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let transparent = scaled.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                    "inputBiasVector": CIVector(x: useDarkInk ? 0 : 1, y: useDarkInk ? 0 : 1, z: useDarkInk ? 0 : 1, w: 0)
                ])
                return context.createCGImage(transparent, from: transparent.extent)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.frame = rendered
                self.isRendering = false
            }
        }
    }

    func stop() {
        playbackGeneration += 1
        isRendering = false
        displayLink?.invalidate()
        displayLink = nil
        player?.pause()
        player = nil
        output = nil
    }
}
