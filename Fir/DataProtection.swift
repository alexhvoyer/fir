import Foundation

/// The entitlement gives new files the "complete unless open" class; files written by older builds
/// kept the weaker default and are moved over once.
enum DataProtection {
    private static let doneKey = "dataProtectionUpgraded"

    static func upgradeExistingFiles() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        Task.detached(priority: .utility) {
            // Only Fir's own folders: WebKit's caches belong to its processes.
            let roots = [URL.applicationSupportDirectory, .documentsDirectory,
                         .cachesDirectory.appending(path: "snapshots-v2"), .cachesDirectory.appending(path: "favicons")]
            var failed = false
            for root in roots {
                failed = !protect(root) || failed
                let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileProtectionKey]) { _, _ in
                    failed = true
                    return true
                }
                while let file = files?.nextObject() as? URL {
                    failed = !protect(file) || failed
                }
            }
            // A file that couldn't be changed is tried again on the next launch.
            if !failed { UserDefaults.standard.set(true, forKey: doneKey) }
        }
    }

    private static func protect(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        let current = try? url.resourceValues(forKeys: [.fileProtectionKey]).fileProtection
        guard current != .complete, current != .completeUnlessOpen else { return true }
        return (try? (url as NSURL).setResourceValue(URLFileProtection.completeUnlessOpen, forKey: .fileProtectionKey)) != nil
    }
}
