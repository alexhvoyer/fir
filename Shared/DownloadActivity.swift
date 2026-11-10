import ActivityKit

/// The Live Activity for downloads: the app starts it, the widget extension draws it.
struct DownloadAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable { case running, paused, finished, failed }
        var progress: Double
        /// Files still coming in. No names here: a server chooses them, and this shows on the Lock Screen.
        var count: Int
        var phase: Phase
    }
}
