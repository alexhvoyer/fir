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
        isSignedIn = false
        email = nil
        remoteClients = []
        spacesRecords = []
        zenWorkspaces = nil
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
        async let spaces: Void = loadsSpaces ? loadSpaces(manager) : ()
        do {
            if !engines.isEmpty {
                remoteClients = try await tabsSync.sync(with: manager, engines: engines)
                    .filter { !$0.remoteTabs.isEmpty }
                    .sorted { $0.lastModified > $1.lastModified }
            }
            lastError = nil
            lastSynced = .now
            // The profile fetch kicked off at sign-in has usually landed by now.
            email = manager.accountProfile()?.email
        } catch {
            lastError = "\(error)"
        }
        if !engines.contains("tabs") { remoteClients = [] }
        await spaces
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
    func addToZen(_ url: URL, title: String, in space: ZenWorkspaces.Space, essential: Bool) async -> String? {
        guard let manager else { return nil }
        // Zen's own id format: milliseconds, then a bare UUID.
        let id = "\(Int(Date.now.timeIntervalSince1970 * 1000))-\(UUID().uuidString.lowercased())"
        let container: Any = space.container == ZenWorkspaces.defaultContainer ? NSNull() : space.container
        let record: [String: Any] = [
            "id": id, "kind": "tab",
            "data": [
                "tabId": id, "url": url.absoluteString, "title": title, "icon": NSNull(),
                "containerGuid": container, "essential": essential, "pinned": true,
                "workspaceUuid": essential ? NSNull() : space.id as Any, "folderId": NSNull(), "staticLabel": NSNull(),
                "hasStaticIcon": false, "defaultContainer": false,
            ] as [String: Any],
        ]
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

    /// Removes a pin or essential this app added; Zen closes the tab when the tombstone reaches it.
    func removeFromZen(_ id: String) async {
        guard let manager else { return }
        if pendingAdds.removeValue(forKey: id) == nil { pendingRemovals.insert(id) }
        rebuildSpaces()
        do {
            try await SyncStorageReader(auth: RemoteTabsSync.authInfo(for: manager))
                .upload([["id": id, "deleted": true]], to: "spaces")
        } catch {
            spacesError = "\(error)"
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
        do {
            let reader = SyncStorageReader(auth: try await RemoteTabsSync.authInfo(for: manager))
            spacesRecords = try await reader.records(in: "spaces")
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
