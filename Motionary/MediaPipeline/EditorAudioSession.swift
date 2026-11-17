// Application audio-session configuration for editor playback.

import AVFoundation
import Synchronization

/// Configures the shared audio session for movie playback.
enum EditorAudioSession {
    private static let coordinator = AudioSessionCoordinator()

    static func configurePlayback() {
        Task { await coordinator.activate() }
    }

    static func preparePlayback() async {
        await coordinator.activate()
    }
}

private actor AudioSessionCoordinator {
    private let generation = Atomic<Int>(0)
    private var activeGeneration: Int?
    private var observers: [NSObjectProtocol] = []

    func activate() {
        let session = AVAudioSession.sharedInstance()
        if observers.isEmpty {
            // Notifications can arrive while setActive is in flight. Tag the
            // result with the generation captured before that call.
            observers = [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification]
                .map { name in
                    NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) {
                        [weak self] _ in _ = self?.generation.wrappingAdd(1, ordering: .releasing)
                    }
                }
        }
        let requested = generation.load(ordering: .acquiring)
        guard activeGeneration != requested else { return }
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            activeGeneration = requested
        } catch {
            activeGeneration = nil
            AppLogger.media.error(
                "Failed to configure audio session: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
