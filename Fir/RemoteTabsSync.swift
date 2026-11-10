import Foundation
import MozillaAppServices

/// Runs Firefox Sync engines ("tabs", "history", "passwords") and reads back other devices' open tabs.
final class RemoteTabsSync: @unchecked Sendable {
    private static let persistedStateKey = "syncPersistedState"
    private let store: TabsStore
    private let syncManager = SyncManagerComponent()

    init() throws {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        store = TabsStore(path: dir.appendingPathComponent("tabs.db").path)
        store.registerWithSyncManager()
    }

    /// After sign-out: nothing of this account stays here, or merges into the next one. In this order,
    /// so disconnecting also drops anything the wipes queued for upload.
    func wipeLocalData() async {
        await Task.detached { [syncManager] in
            PasswordStore.shared?.wipeLocal()
            HistoryStore.shared?.wipeLocal()
            syncManager.disconnect()
            UserDefaults.standard.removeObject(forKey: Self.persistedStateKey)
        }.value
    }

    /// Engines left out are skipped on this device only; declining them would turn them off account-wide.
    @MainActor
    /// The other devices' tabs, plus the first engine that failed: one failing, say passwords,
    /// still leaves the tabs that did sync.
    func sync(with manager: FxAccountManager, engines: [String]) async throws -> (clients: [ClientRemoteTabs], failure: String?) {
        let deviceID = try await call { manager.getCurrentDeviceId(completionHandler: $0) }
        let params = SyncParams(
            reason: .user,
            engines: .some(engines: engines),
            enabledChanges: [:],
            // Empty even for passwords: the logins engine takes its key from its own store.
            localEncryptionKeys: [:],
            authInfo: try await Self.authInfo(for: manager),
            persistedState: UserDefaults.standard.string(forKey: Self.persistedStateKey),
            deviceSettings: DeviceSettings(
                fxaDeviceId: deviceID,
                name: manager.deviceConfig.name,
                kind: manager.deviceConfig.deviceType
            )
        )

        // Both calls block on network and disk, so keep them off the main actor.
        return try await Task.detached { [store, syncManager] in
            let result = try syncManager.sync(params: params)
            if !result.persistedState.isEmpty {
                UserDefaults.standard.set(result.persistedState, forKey: Self.persistedStateKey)
            }
            // Offline, a revoked login or a server backoff comes back as a status, not a thrown error.
            guard result.status == .ok else { throw SyncError.service("\(result.status)") }
            let failure = result.failures.first.map { "\($0.key): \($0.value)" }
            return (engines.contains("tabs") ? store.getAll() : [], failure)
        }.value
    }

    /// Token-server credentials for the Sync storage, shared with SyncStorageReader.
    @MainActor
    static func authInfo(for manager: FxAccountManager) async throws -> SyncAuthInfo {
        let token = try await call { manager.getAccessToken(scope: OAuthScope.oldSync, completionHandler: $0) }
        let tokenServer = try await call { manager.getTokenServerEndpointURL(completionHandler: $0) }
        guard let key = token.key else { throw SyncError.missingScopedKey }
        return SyncAuthInfo(
            kid: key.kid,
            fxaAccessToken: token.token,
            syncKey: key.k,
            tokenserverUrl: tokenServer.absoluteString
        )
    }

    enum SyncError: Error {
        case missingScopedKey
        case service(String)
    }
}

/// Bridges the account manager's completion-handler API to async/await.
@MainActor
private func call<T>(_ body: (@escaping @MainActor @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        body { continuation.resume(with: $0) }
    }
}
