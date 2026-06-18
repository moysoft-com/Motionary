// Application audio-session configuration for editor playback.

import AVFoundation

/// Configures the shared audio session for movie playback.
enum EditorAudioSession {
    static func configurePlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            AppLogger.media.error(
                "Failed to configure audio session: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
