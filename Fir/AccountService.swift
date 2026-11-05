import SwiftUI
import MozillaAppServices

/// Mozilla account state plus the remote tabs pulled from Firefox Sync.
@MainActor
@Observable
final class AccountService {
    // Firefox for iOS's public OAuth client: Mozilla does not hand out Sync access to third parties.
    // Fine for a personal build, not for distribution.
    static let clientID = "1b1a3e44c54fbb58"
    static let redirectURI = "urn:ietf:wg:oauth:2.0:oob:oauth-redirect-webchannel"
    static let contentServer = URL(string: "https://accounts.firefox.com")!

    private(set) var manager: FxAccountManager?
    private(set) var email: String?
    private(set) var remoteClients: [ClientRemoteTabs] = []

    /// Devices whose tabs the user turned off in Sync settings; kept on this iPhone only.
    private(set) var hiddenDevices = Set(UserDefaults.standard.stringArray(forKey: SettingsKey.hiddenDevices) ?? [])

    func setTabsShown(_ shown: Bool, for clientId: String) {
        if shown { hiddenDevices.remove(clientId) } else { hiddenDevices.insert(clientId) }
        UserDefaults.standard.set(Array(hiddenDevices), forKey: SettingsKey.hiddenDevices)
    }

    /// Devices whose tabs are shown, synced in the last two weeks; older ones are usually retired machines.
    var recentClients: [ClientRemoteTabs] {
        let cutoff = Int64((Date.now.timeIntervalSince1970 - 14 * 24 * 3600) * 1000)
        return remoteClients.filter { $0.lastModified >= cutoff && !hiddenDevices.contains($0.clientId) }
    }
    private(set) var zenWorkspaces: ZenWorkspaces?
    /// The "spaces" records as last fetched, before local changes are laid over them.
    private var spacesRecords: [[String: Any]] = []
    /// Pins and essentials added here, shown at once: Zen lists an essential in its layout only after it
    /// syncs, minutes later. Each stays until the fetched records show it.
    private var pendingAdds: [String: (record: [String: Any], container: String?)] = [:]
    private var pendingRemovals: Set<String> = []
    private(set) var spacesError: String?
    private(set) var isSyncing = false
    private(set) var lastSynced: Date?
    private(set) var lastError: String?
    // Stored, not derived from manager.hasAccount(): Observation can't see state inside the Rust account.
    private(set) var isSignedIn = false

    private var tabsSync: RemoteTabsSync?
    /// Bumped by sign-out; a sync still running from before must not bring the old account's data back.
    private var generation = 0

    /// Other devices on the account that accept tabs sent from here, such as Zen on the Mac.
    private(set) var sendTargets: [Device] = []
    /// Tabs other devices sent here; the browser opens them and empties the list.
    var receivedTabs: [URL] = []

    /// The last synced workspaces and devices, shown at launch while the first sync runs.
    init() {
        guard let cache = SyncCache.load() else { return }
        spacesRecords = cache.spaces
        remoteClients = cache.clients
        rebuildSpaces()
    }

    func start() async {
        guard manager == nil else { return }
        let manager = FxAccountManager(
            config: FxAConfig(server: .release, clientId: Self.clientID, redirectUri: Self.redirectURI),
            deviceConfig: DeviceConfig(
                name: "Fir on \(UIDevice.current.name)",
                deviceType: .mobile,
                // Lets Zen list this iPhone under "Send Tab to Device".
                capabilities: [.sendTab]
            ),
            applicationScopes: [OAuthScope.profile, OAuthScope.oldSync, OAuthScope.session]
        )
        let result = await withCheckedContinuation { continuation in
            manager.initialize { continuation.resume(returning: $0) }
        }
        self.manager = manager
        NotificationCenter.default.addObserver(forName: .constellationStateUpdate, object: nil, queue: .main) { [weak self] note in
            guard let state = note.userInfo?["newState"] as? ConstellationState else { return }
            let targets = state.remoteDevices.filter { $0.capabilities.contains(.sendTab) }
            MainActor.assumeIsolated { self?.sendTargets = targets }
        }
        isSignedIn = manager.hasAccount()
        if case .failure(let error) = result { lastError = "\(error)" }
        // Shown from the cache at launch; with no account (say, its keychain entry gone) it is someone's old data.
        if case .success = result, !isSignedIn {
            remoteClients = []
            spacesRecords = []
            zenWorkspaces = nil
            SyncCache.clear()
        }
        tabsSync = try? RemoteTabsSync()
        refreshProfile()
        if isSignedIn { await sync() }
    }

    /// The URL of the Mozilla sign-in page that starts the OAuth flow.
    func beginSignIn() async -> URL? {
        guard let manager else { return nil }
        let result = await withCheckedContinuation { continuation in
            manager.beginAuthentication(
                entrypoint: "fir",
                scopes: [OAuthScope.profile, OAuthScope.oldSync]
            ) { continuation.resume(returning: $0) }
        }
        switch result {
        case .success(let url): return url
        case .failure(let error): lastError = "\(error)"; return nil
        }
    }

    func finishSignIn(code: String, state: String) async {
        guard let manager else { return }
        let auth = FxaAuthData(code: code, state: state, actionQueryParam: "signin")
        let result = await withCheckedContinuation { continuation in
            manager.finishAuthentication(authData: auth) { continuation.resume(returning: $0) }
        }
        if case .failure(let error) = result { lastError = "\(error)"; return }
        isSignedIn = true
        refreshProfile()
        await sync()
    }

    func signOut() async {
        guard let manager else { return }
        _ = await withCheckedContinuation { continuation in
            manager.logout { continuation.resume(returning: $0) }
        }
        generation += 1
        isSignedIn = false
        email = nil
        remoteClients = []
        spacesRecords = []
        pendingAdds = [:]
        pendingRemovals = []
        zenWorkspaces = nil
        sendTargets = []
        receivedTabs = []
        SyncCache.clear()
    }

    func sync() async {
        guard let manager, let tabsSync, isSignedIn, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let defaults = UserDefaults.standard
        var engines: [String] = []
        if defaults.bool(forKey: SettingsKey.syncTabs, default: true) { engines.append("tabs") }
        // The history engine exists only once Places has registered it.
        if defaults.bool(forKey: SettingsKey.syncHistory, default: true), HistoryStore.shared != nil { engines.append("history") }
        if defaults.bool(forKey: SettingsKey.syncPasswords, default: true), PasswordStore.shared != nil {
            engines.append(PasswordStore.engine)
        }
        // Zen's workspaces load alongside the tabs, not after them: the deck waits on both at launch.
        let loadsSpaces = defaults.bool(forKey: SettingsKey.syncWorkspaces, default: true)
        let generation = generation
        async let spaces: Void = loadsSpaces ? loadSpaces(manager) : ()
        do {
            var failure: String?
            if !engines.isEmpty {
                let synced = try await tabsSync.sync(with: manager, engines: engines)
                guard generation == self.generation else { return }
                remoteClients = synced.clients
                    .filter { !$0.remoteTabs.isEmpty }
                    .sorted { $0.lastModified > $1.lastModified }
                failure = synced.failure
            }
            lastError = failure
            if failure == nil { lastSynced = .now }
            // The profile fetch kicked off at sign-in has usually landed by now.
            email = manager.accountProfile()?.email
        } catch {
            guard generation == self.generation else { return }
            lastError = "\(error)"
        }
        if !engines.contains("tabs") { remoteClients = [] }
        await spaces
        guard generation == self.generation else { return }
        if !loadsSpaces {
            spacesRecords = []
            zenWorkspaces = nil
        }
        SyncCache.save(spaces: spacesRecords, clients: remoteClients)
        await fetchDeviceCommands(manager)
    }

    /// Sends a page to another device's browser.
    func send(_ url: URL, title: String, to device: Device) async -> Bool {
        guard let constellation = manager?.deviceConstellation() else { return false }
        return await withCheckedContinuation { continuation in
            constellation.sendEventToDevice(targetDeviceId: device.id,
                                            e: .sendTab(title: title, url: url.absoluteString)) {
                if case .success = $0 { continuation.resume(returning: true) } else { continuation.resume(returning: false) }
            }
        }
    }

    /// Without push, tabs sent here wait on the server until asked for; every sync asks.
    private func fetchDeviceCommands(_ manager: FxAccountManager) async {
        guard let constellation = manager.deviceConstellation() else { return }
        constellation.refreshState()
        let result = await withCheckedContinuation { continuation in
            constellation.pollForCommands { continuation.resume(returning: $0) }
        }
        guard case .success(let commands) = result else { return }
        for case .tabReceived(_, let payload) in commands {
            if let url = payload.entries.last.flatMap({ URL(string: $0.url) }) { receivedTabs.append(url) }
        }
    }

    /// Adds a page to Zen as its own "Pin Tab" or "Add to Essentials" would: one new tab record in the
    /// "spaces" collection, which Zen creates on its next sync. A pin belongs to `space`; an essential to
    /// the space's container, so it shows in every space using it. Returns the record id.
    func addToZen(_ url: URL, title: String, in space: ZenWorkspaces.Space, essential: Bool,
                  id: String = AccountService.newRecordID(), folderID: String? = nil) async -> String? {
        guard let manager else { return nil }
        let record = Self.tabRecord(id: id, url: url, title: title, in: space, essential: essential, folderID: folderID)
        pendingAdds[id] = (record, essential ? space.container : nil)
        rebuildSpaces()
        do {
            try await SyncStorageReader(auth: RemoteTabsSync.authInfo(for: manager)).upload([record], to: "spaces")
            return id
        } catch {
            pendingAdds[id] = nil
            rebuildSpaces()
            spacesError = "\(error)"
            return nil
        }
    }

    /// Zen's own id format: milliseconds, then a bare UUID.
    nonisolated static func newRecordID() -> String {
        "\(Int(Date.now.timeIntervalSince1970 * 1000))-\(UUID().uuidString.lowercased())"
    }

    /// Changes one record of Zen's: read fresh, changed, and written back only if nobody wrote it meanwhile,
    /// else read again. Shown at once, and undone if it never lands.
    private func updateZenRecord(_ id: String, _ change: @escaping ([String: Any]) -> [String: Any]) async -> Bool {
        guard let manager else { return false }
        let before = spacesRecords
        if let index = spacesRecords.firstIndex(where: { $0["id"] as? String == id }),
           let data = spacesRecords[index]["data"] as? [String: Any] {
            spacesRecords[index]["data"] = change(data)
            rebuildSpaces()
        }
        do {
            let storage = SyncStorageReader(auth: try await RemoteTabsSync.authInfo(for: manager))
            for _ in 0..<3 {
                var (record, modified) = try await storage.record(id, in: "spaces")
                record["data"] = change(record["data"] as? [String: Any] ?? [:])
                do {
                    try await storage.replace(record, in: "spaces", ifUnmodifiedSince: modified)
                    return true
                } catch SyncStorageReader.ReaderError.conflict {
                    continue
                }
            }
            throw SyncStorageReader.ReaderError.conflict
        } catch {
            spacesRecords = before
            rebuildSpaces()
            spacesError = "\(error)"
            return false
        }
    }

    func renameZenSpace(_ id: String, to name: String, icon: String?) async -> Bool {
        await updateZenRecord(id) { data in
            var data = data
            data["name"] = name
            data["icon"] = icon ?? NSNull()
            return data
        }
    }

    /// Zen's workspace order; the layout record also holds every container's essentials, which stay as read.
    func reorderZenSpaces(_ ids: [String]) async -> Bool {
        await updateZenRecord("layout") { data in
            var data = data
            data["spaces"] = ids
            return data
        }
    }

    /// Asks Zen to delete a workspace. Zen confirms on the computer first, and closes its tabs there.
    func deleteZenSpace(_ id: String) async -> Bool {
        await removeFromZen(id)
    }

    /// A new Zen workspace, as Zen makes one: its default theme and container, nothing in it yet.
    func createZenSpace(named name: String, icon: String?) async -> Bool {
        guard let manager else { return false }
        let uuid = "{\(UUID().uuidString.lowercased())}"
        let record: [String: Any] = [
            "id": uuid, "kind": "space",
            "data": [
                "uuid": uuid, "name": name, "icon": icon ?? NSNull(),
                "theme": ["type": "gradient", "gradientColors": [Any](), "opacity": 0.5, "texture": 0] as [String: Any],
                "containerGuid": NSNull(), "children": [String](),
            ] as [String: Any],
        ]
        pendingAdds[uuid] = (record, nil)
        rebuildSpaces()
        do {
            try await SyncStorageReader(auth: RemoteTabsSync.authInfo(for: manager)).upload([record], to: "spaces")
            return true
        } catch {
            pendingAdds[uuid] = nil
            rebuildSpaces()
            spacesError = "\(error)"
            return false
        }
    }

    /// A new Zen folder holding pages, sent in one batch: Zen applies folders before tabs, so the tabs
    /// land inside it. False when the server didn't take them all.
    func createZenFolder(id: String, named name: String, in space: ZenWorkspaces.Space,
                         tabs: [(id: String, url: URL, title: String)]) async -> Bool {
        guard let manager else { return false }
        let folder: [String: Any] = [
            "id": id, "kind": "folder",
            "data": [
                "folderId": id, "name": name, "icon": NSNull(), "workspaceUuid": space.id,
                "parentFolderId": NSNull(), "live": NSNull(), "children": tabs.map(\.id),
            ] as [String: Any],
        ]
        let records = tabs.map { Self.tabRecord(id: $0.id, url: $0.url, title: $0.title, in: space, essential: false, folderID: id) }
        pendingAdds[id] = (folder, nil)
        for (tab, record) in zip(tabs, records) { pendingAdds[tab.id] = (record, nil) }
        rebuildSpaces()
        do {
            try await SyncStorageReader(auth: RemoteTabsSync.authInfo(for: manager)).upload([folder] + records, to: "spaces")
            return true
        } catch {
            pendingAdds[id] = nil
            for tab in tabs { pendingAdds[tab.id] = nil }
            rebuildSpaces()
            spacesError = "\(error)"
            return false
        }
    }

    /// A pinned tab, an essential, or a folder's tab, as Zen's own sync writes one.
    private static func tabRecord(id: String, url: URL, title: String, in space: ZenWorkspaces.Space,
                                  essential: Bool, folderID: String?) -> [String: Any] {
        let container: Any = space.container == ZenWorkspaces.defaultContainer ? NSNull() : space.container
        return [
            "id": id, "kind": "tab",
            "data": [
                "tabId": id, "url": url.absoluteString, "title": title, "icon": NSNull(),
                "containerGuid": container, "essential": essential, "pinned": true,
                "workspaceUuid": essential ? NSNull() : space.id as Any, "folderId": folderID ?? NSNull() as Any,
                "staticLabel": NSNull(), "hasStaticIcon": false, "defaultContainer": false,
            ] as [String: Any],
        ]
    }

    /// Removes a pin or essential this app added; Zen closes the tab when the tombstone reaches it.
    /// False when the deletion didn't reach the server; the item then shows again, as Zen still has it.
    @discardableResult func removeFromZen(_ id: String) async -> Bool {
        guard let manager else { return false }
        let hidden = pendingAdds.removeValue(forKey: id) == nil
        if hidden { pendingRemovals.insert(id) }
        rebuildSpaces()
        do {
            try await SyncStorageReader(auth: RemoteTabsSync.authInfo(for: manager))
                .upload([["id": id, "deleted": true]], to: "spaces")
            return true
        } catch {
            if hidden { pendingRemovals.remove(id) }
            rebuildSpaces()
            spacesError = "\(error)"
            return false
        }
    }

    /// The fetched records with this device's pending pins and essentials laid over them; a pending change
    /// is dropped once the fetched records already show it.
    private func rebuildSpaces() {
        let live = spacesRecords.filter { $0["deleted"] as? Bool != true }
        let ids = Set(live.compactMap { $0["id"] as? String })
        let layoutEssentials = ((live.first { $0["id"] as? String == "layout" }?["data"] as? [String: Any])?["essentials"]
            as? [String: [String]] ?? [:]).values.flatMap { $0 }
        for (id, pending) in pendingAdds {
            let shown = pending.container == nil ? ids.contains(id) : layoutEssentials.contains(id)
            if shown { pendingAdds[id] = nil }
        }
        pendingRemovals = pendingRemovals.filter { ids.contains($0) || layoutEssentials.contains($0) }

        var records = spacesRecords.filter { !pendingRemovals.contains($0["id"] as? String ?? "") }
        records += pendingAdds.compactMap { ids.contains($0.key) ? nil : $0.value.record }
        let essentials = pendingAdds.compactMap { id, pending in pending.container.map { (id, $0) } }
        if !essentials.isEmpty || !pendingRemovals.isEmpty,
           let index = records.firstIndex(where: { $0["id"] as? String == "layout" }) {
            var layout = records[index]
            var data = layout["data"] as? [String: Any] ?? [:]
            var lists = data["essentials"] as? [String: [String]] ?? [:]
            for key in lists.keys { lists[key]?.removeAll { pendingRemovals.contains($0) } }
            for (id, container) in essentials where !(lists[container]?.contains(id) ?? false) {
                lists[container, default: []].append(id)
            }
            data["essentials"] = lists
            layout["data"] = data
            records[index] = layout
        }
        zenWorkspaces = records.isEmpty ? nil : ZenWorkspaces(records: records)
    }

    private func loadSpaces(_ manager: FxAccountManager) async {
        let generation = generation
        do {
            let reader = SyncStorageReader(auth: try await RemoteTabsSync.authInfo(for: manager))
            let records = try await reader.records(in: "spaces")
            guard generation == self.generation else { return }
            spacesRecords = records
            rebuildSpaces()
            spacesError = nil
        } catch {
            spacesError = "\(error)"
        }
    }

    private func refreshProfile() {
        email = manager?.accountProfile()?.email
        if email == nil, isSignedIn { manager?.refreshProfile() }
    }
}

/// Synced workspaces and other devices' tabs kept on disk, so a fresh launch shows them at once.
private enum SyncCache {
    private static var url: URL { URL.applicationSupportDirectory.appending(path: "sync-cache.json") }

    static func load() -> (spaces: [[String: Any]], clients: [ClientRemoteTabs])? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let clients = (json["clients"] as? [[String: Any]] ?? []).compactMap { client -> ClientRemoteTabs? in
            guard let id = client["id"] as? String, let name = client["name"] as? String else { return nil }
            let tabs = (client["tabs"] as? [[String: Any]] ?? []).map { tab in
                RemoteTabRecord(title: tab["title"] as? String ?? "", urlHistory: tab["urls"] as? [String] ?? [],
                                icon: nil, lastUsed: (tab["lastUsed"] as? NSNumber)?.int64Value ?? 0,
                                pinned: tab["pinned"] as? Bool ?? false)
            }
            return ClientRemoteTabs(clientId: id, clientName: name,
                                    deviceType: client["mobile"] as? Bool == true ? .mobile : .desktop,
                                    lastModified: (client["modified"] as? NSNumber)?.int64Value ?? 0,
                                    remoteTabs: tabs, tabGroups: [:], windows: [:])
        }
        return (json["spaces"] as? [[String: Any]] ?? [], clients)
    }

    static func save(spaces: [[String: Any]], clients: [ClientRemoteTabs]) {
        let json: [String: Any] = [
            "spaces": spaces,
            "clients": clients.map { client in
                [
                    "id": client.clientId, "name": client.clientName, "mobile": client.deviceType == .mobile,
                    "modified": client.lastModified,
                    "tabs": client.remoteTabs.map {
                        ["title": $0.title, "urls": $0.urlHistory, "lastUsed": $0.lastUsed, "pinned": $0.pinned] as [String: Any]
                    },
                ] as [String: Any]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}
