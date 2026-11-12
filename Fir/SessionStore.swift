import UIKit

/// Open tabs survive relaunch as a small JSON file plus one JPEG card snapshot per tab.
/// Only addresses are kept: WebPage exposes no back/forward state to restore.
enum SessionStore {
    struct Tab: Codable {
        let id: UUID
        let url: URL?
        let title: String
        /// Missing in sessions saved before workspaces kept their own tabs; decodes as nil.
        let spaceID: String?
        /// Missing before tabs were archived; restored tabs then count as viewed at launch.
        var lastViewed: Date? = nil
        var pinned: Bool? = nil
        /// The Zen records this tab's pin and essential created, so they can be removed again.
        var zenPinID: String? = nil
        var zenEssentialID: String? = nil
        /// Stands for a tab of a Zen folder, kept in step with Zen rather than opened here.
        var zenFolder: Bool? = nil
        /// The folder of this iPhone's own tabs it is in.
        var localFolder: UUID? = nil
        /// The pin of this iPhone's tabs it stands for.
        var localPin: UUID? = nil
    }

    struct Session: Codable {
        let tabs: [Tab]
        let selectedID: UUID?
        var localFolders: [LocalFolder]? = nil
        var localPins: [LocalPin]? = nil
    }

    private static var sessionURL: URL {
        URL.applicationSupportDirectory.appending(path: "session.json")
    }

    /// Snapshots live in Caches: losing them only costs a placeholder card.
    private static var snapshotsURL: URL {
        // v2: full-screen WKWebView snapshots; the older ones were cropped differently and misplaced content.
        URL.cachesDirectory.appending(path: "snapshots-v2", directoryHint: .isDirectory)
    }

    /// Nil when there is none. Throws when the file is there but unreadable, as at a launch while the phone is locked.
    static func load() throws -> Session? {
        let data: Data
        do { data = try Data(contentsOf: sessionURL) } catch CocoaError.fileReadNoSuchFile { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func save(_ session: Session) {
        do {
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(session).write(to: sessionURL, options: .atomic)
        } catch {
            NSLog("Fir: failed to save session: \(error)")
        }
    }

    static func loadSnapshot(for id: UUID) -> UIImage? {
        UIImage(contentsOfFile: snapshotFile(id).path)
    }

    static func saveSnapshot(_ data: Data, for id: UUID) {
        let file = snapshotFile(id)
        Task.detached(priority: .utility) {
            // Re-encode as JPEG to keep the cache small whatever format the export used.
            guard let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.7) else { return }
            try? FileManager.default.createDirectory(at: snapshotsURL, withIntermediateDirectories: true)
            try? jpeg.write(to: file, options: .atomic)
        }
    }

    static func deleteSnapshot(for id: UUID) {
        try? FileManager.default.removeItem(at: snapshotFile(id))
    }

    private static func snapshotFile(_ id: UUID) -> URL {
        snapshotsURL.appending(path: "\(id.uuidString).jpg")
    }
}
