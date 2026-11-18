import AVFoundation
import SwiftUI

struct MotionaryVideoPlayer: View {
    let movie: MotionaryVideoArchive.Movie

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var player = AVPlayer()
    @State private var haptics = HapticPlayback()
    @State private var hapticsEnabled = true
    @State private var speed: Float = 1
    @State private var controlsVisible = true
    @Environment(\.layoutDirection) private var layoutDirection
    @GestureState private var scrubGestureActive = false
    @State private var holdingControlsForMenu = false
    @State private var controlsRevision = UUID()

    private let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    @State private var duration = 0.0
    @State private var position = 0.0
    @State private var isPlaying = false
    @State private var didFinish = false
    @State private var playbackFailed = false
    @State private var scrubPosition: Double?
    @State private var scrubStart = 0.0
    @State private var previewSeekInFlight = false
    @State private var resumeAfterScrubbing = false
    @State private var pendingSeek = false
    @State private var seekID = UUID()
    @State private var timeObserver: Any?
    @State private var playbackObservation: NSKeyValueObservation?
    @State private var itemObservation: NSKeyValueObservation?

    private var hasHaptics: Bool { !movie.haptics.events.isEmpty }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                videoAndTransport
                    .ignoresSafeArea()
                if controlsVisible {
                    controls
                        .padding(.horizontal, MotionaryDesign.Spacing.xxl)
                        .padding(.bottom, MotionaryDesign.Spacing.sm)
                        .zIndex(1)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background {
                PlayerNavigationBarVisibility(visible: controlsVisible, animated: !reduceMotion)
                    .frame(width: 0, height: 0)
            }
            .navigationTitle(movie.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close Player")
                }
            }
        }
        .background { Color.black.ignoresSafeArea() }
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
        .statusBarHidden(true)
        .task(id: controlsRevision) {
            guard controlsVisible, isPlaying, !holdingControlsForMenu, scrubPosition == nil,
                !UIAccessibility.isVoiceOverRunning else { return }
            do { try await Task.sleep(for: .seconds(3.5)) } catch { return }
            setControlsVisible(false)
        }
        .onChange(of: isPlaying) { _, playing in
            if playing { keepControlsVisible() }
            else if scrubPosition == nil { setControlsVisible(true) }
        }
        .task { await preparePlayback() }
        .onChange(of: scrubGestureActive) { _, active in
            if !active { finishScrubbing() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                resumeAfterScrubbing = false
                seekID = UUID()
                pendingSeek = false
                player.pause()
                finishScrubbing()
            }
            updateHaptics()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard note.object as? AVPlayerItem === player.currentItem, !pendingSeek, scrubPosition == nil else { return }
            didFinish = true
            position = duration
        }
        .onDisappear { tearDownPlayback() }
    }

    private var videoAndTransport: some View {
        ZStack {
            MotionaryVideoSurface(player: player)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button {
                setControlsVisible(!controlsVisible)
            } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show Playback Controls")
            .accessibilityHidden(controlsVisible)
            if playbackFailed {
                ContentUnavailableView("Video Unavailable", systemImage: "play.rectangle")
            } else if duration <= 0 {
                ProgressView().tint(MotionaryTheme.accent)
                    .accessibilityLabel("Loading video")
            }
            if controlsVisible {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.72), location: 0),
                    .init(color: .clear, location: 0.28),
                    .init(color: .clear, location: 0.65),
                    .init(color: .black.opacity(0.72), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
                .transition(.opacity)
                transport.transition(.opacity)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: MotionaryDesign.Spacing.lg) {
            Menu {
                Picker("Playback Speed", selection: Binding(get: { speed }, set: setSpeed)) {
                    ForEach(speeds, id: \.self) { rate in
                        Text(rateLabel(rate)).tag(rate)
                    }
                }
            } label: {
                Text(rateLabel(speed))
                    .font(MotionaryDesign.Typography.controlValue)
                    .frame(width: 50, height: 44)
                    .motionaryInteractiveGlassEffect(in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Playback Speed")
            .accessibilityValue(rateLabel(speed))
            .simultaneousGesture(TapGesture().onEnded {
                holdingControlsForMenu = true
                controlsRevision = UUID()
            })

            scrubber
                .frame(maxWidth: .infinity)

            let canPlayHaptics = hasHaptics && HapticPlayback.isSupported
            roundButton(
                hapticsEnabled ? "Mute Haptics" : "Enable Haptics",
                symbol: "waveform.path",
                foreground: canPlayHaptics && hapticsEnabled ? .white : .gray
            ) {
                hapticsEnabled.toggle()
                updateHaptics()
                keepControlsVisible()
            }
            .accessibilityValue(canPlayHaptics ? (hapticsEnabled ? "On" : "Off") : "Unavailable")
            .disabled(!canPlayHaptics)
        }
        .frame(maxWidth: 760)
    }

    private var scrubber: some View {
        let displayedPosition = scrubPosition ?? position
        let progress = duration > 0 ? max(0, min(displayedPosition / duration, 1)) : 0
        return VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.clear)
                    Rectangle()
                        .fill(.white.opacity(0.92))
                        .frame(width: geometry.size.width * progress)
                }
                .clipShape(Capsule())
                .motionaryInteractiveGlassEffect(in: Capsule())
                .frame(height: 9)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2)
                    .updating($scrubGestureActive) { _, active, _ in active = true }
                    .onChanged { value in
                        guard scenePhase == .active, duration > 0, !playbackFailed, geometry.size.width > 0 else { return }
                        let direction = layoutDirection == .rightToLeft ? -1.0 : 1.0
                        let offset = direction * value.translation.width / geometry.size.width * duration
                        updateScrub(offset: offset)
                    }
                    .onEnded { _ in finishScrubbing() }
                )
            }
            .frame(height: 30)

            HStack {
                Text(formatClock(displayedPosition))
                Spacer()
                Text(formatClock(duration))
            }
            .font(MotionaryDesign.Typography.controlValue)
            .foregroundStyle(.white.opacity(0.8))
            .accessibilityHidden(true)
        }
        .disabled(duration <= 0 || playbackFailed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback Position")
        .accessibilityValue(Text("\(formatClock(displayedPosition)) of \(formatClock(duration))"))
        .accessibilityAdjustableAction { direction in
            guard duration > 0, !playbackFailed else { return }
            switch direction {
            case .increment: seek(to: position + 5)
            case .decrement: seek(to: position - 5)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("motionary-video-scrubber")
    }

    private var transport: some View {
        HStack(spacing: 22) {
            roundButton("Back 10 Seconds", symbol: "gobackward.10", size: 48) { seek(to: position - 10) }
            roundButton(
                didFinish ? "Replay" : isPlaying ? "Pause" : "Play",
                symbol: didFinish ? "play.fill" : isPlaying ? "pause.fill" : "play.fill",
                size: 64, prominent: true, action: togglePlayback
            )
            .accessibilityIdentifier("motionary-video-playback")
            .disabled(pendingSeek || scrubPosition != nil)
            roundButton("Forward 10 Seconds", symbol: "goforward.10", size: 48) { seek(to: position + 10) }
        }
        .disabled(duration <= 0 || playbackFailed || scrubPosition != nil)
        .opacity(duration > 0 && !playbackFailed ? 1 : 0)
    }

    private func roundButton(
        _ title: LocalizedStringKey, symbol: String, size: CGFloat = 44, prominent: Bool = false,
        foreground: Color = .white, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 24 : 17, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(prominent ? MotionaryTheme.foregroundOnAccent : foreground)
                .background(prominent ? MotionaryTheme.accent : .clear, in: .circle)
                .motionaryInteractiveGlassEffect(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func rateLabel(_ rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private func setSpeed(_ rate: Float) {
        speed = rate
        player.defaultRate = rate
        if player.rate > 0 { player.rate = rate }
        keepControlsVisible()
    }

    private func keepControlsVisible() {
        holdingControlsForMenu = false
        controlsRevision = UUID()
    }

    private func setControlsVisible(_ visible: Bool) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            controlsVisible = visible
        }
        keepControlsVisible()
    }

    private func preparePlayback() async {
        guard player.currentItem == nil else { return }
        await EditorAudioSession.preparePlayback()
        guard !Task.isCancelled else { return }

        let item = AVPlayerItem(url: movie.url)
        player.replaceCurrentItem(with: item)
        playbackObservation = player.observe(\.rate, options: [.initial, .new]) { _, _ in
            Task { @MainActor in isPlaying = player.rate > 0 }
        }
        itemObservation = item.observe(\.status, options: [.initial, .new]) { _, _ in
            Task { @MainActor in
                if player.currentItem === item, item.status == .failed { playbackFailed = true }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { time in
            MainActor.assumeIsolated {
                guard scrubPosition == nil, !pendingSeek, !didFinish, time.seconds.isFinite else { return }
                position = max(0, min(time.seconds, duration))
            }
        }
        do {
            let seconds = try await item.asset.load(.duration).seconds
            guard !Task.isCancelled, player.currentItem === item else { return }
            guard seconds > 0, seconds < Double(Int.max) else {
                playbackFailed = true
                return
            }
            duration = seconds
            updateHaptics()
            if scenePhase == .active { player.play() }
        } catch {
            guard !Task.isCancelled, player.currentItem === item else { return }
            playbackFailed = true
        }
    }

    private func togglePlayback() {
        keepControlsVisible()
        if didFinish {
            seek(to: 0, resume: true)
        } else if player.rate > 0 {
            player.pause()
        } else {
            player.play()
        }
    }

    private func updateScrub(offset: Double) {
        if scrubPosition == nil {
            let current = player.currentTime().seconds
            scrubStart = !pendingSeek && current.isFinite ? current : position
            resumeAfterScrubbing = player.rate > 0
            player.pause()
            seekID = UUID()
            pendingSeek = false
            keepControlsVisible()
        }

        let destination = max(0, min(scrubStart + offset, duration))
        guard scrubPosition != destination else { return }
        scrubPosition = destination
        requestScrubFrame()
    }

    // Decode one frame at a time and skip intermediate gesture positions while seeking.
    private func requestScrubFrame() {
        guard !previewSeekInFlight, let destination = scrubPosition else { return }
        let request = seekID
        previewSeekInFlight = true
        let tolerance = CMTime(value: 1, timescale: 60)
        player.seek(to: CMTime(seconds: destination, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { _ in
            Task { @MainActor in
                guard seekID == request else { return }
                previewSeekInFlight = false
                if let latest = scrubPosition, latest != destination { requestScrubFrame() }
            }
        }
    }

    private func finishScrubbing() {
        guard let destination = scrubPosition else { return }
        scrubPosition = nil
        previewSeekInFlight = false
        seek(to: destination, resume: resumeAfterScrubbing)
        resumeAfterScrubbing = false
    }

    private func seek(to seconds: Double, resume: Bool = false) {
        keepControlsVisible()
        let destination = max(0, min(seconds, duration))
        let request = UUID()
        seekID = request
        position = destination
        didFinish = destination >= duration
        if didFinish { player.pause() }
        pendingSeek = true
        player.seek(to: CMTime(seconds: destination, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in
                guard seekID == request else { return }
                pendingSeek = false
                if finished, resume, !didFinish, scenePhase == .active { player.play() }
            }
        }
    }

    private func updateHaptics() {
        if hapticsEnabled, scenePhase == .active, player.currentItem != nil {
            haptics.attach(to: player, track: movie.haptics)
        } else {
            haptics.detach()
        }
    }

    private func tearDownPlayback() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        playbackObservation = nil
        itemObservation = nil
        seekID = UUID()
        pendingSeek = false
        previewSeekInFlight = false
        scrubPosition = nil
        haptics.detach()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

private struct PlayerNavigationBarVisibility: UIViewControllerRepresentable {
    let visible: Bool
    let animated: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.visible = visible
        controller.animated = animated
        controller.updateNavigationBar()
    }

    final class Controller: UIViewController {
        var visible = true
        var animated = true

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updateNavigationBar()
        }

        func updateNavigationBar() {
            guard let navigationController, navigationController.isNavigationBarHidden == visible else { return }
            navigationController.setNavigationBarHidden(!visible, animated: animated)
        }
    }
}

private struct MotionaryVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.videoLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.videoLayer.player = player
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: Void) {
        view.videoLayer.player = nil
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
