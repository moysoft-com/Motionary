import Foundation
import UIKit

enum TimelineCacheLifecycle {
    static func installMemoryWarningHandler() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await TimelineThumbnailTileCache.shared.trimForMemoryPressure()
                await TimelineAudioWaveformCache.shared.trimForMemoryPressure()
            }
        }
    }
}
