// Centralized unified-logging categories for persistence and media operations.

import OSLog

enum AppLogger {
    static let persistence = Logger(subsystem: "com.moysoft.motionary", category: "Persistence")
    static let media = Logger(subsystem: "com.moysoft.motionary", category: "Media")
    static let rendering = Logger(subsystem: "com.moysoft.motionary", category: "Rendering")
}
