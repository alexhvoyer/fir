import ActivityKit

/// The Live Activity for downloads: the app starts it, the widget extension draws it.
struct DownloadAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable { case running, finished, failed }
        var name: String
        var progress: Double
        /// Files still coming in; the name is the newest of them.
        var count: Int
        var phase: Phase
    }
}
