import LocalAuthentication
import SwiftUI

/// Optional Face ID (or passcode) lock, checked at launch and on every return to the app.
@MainActor
@Observable
final class AppLock {
    private(set) var isLocked: Bool
    private var authenticating = false

    init() {
        isLocked = Self.isEnabled
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.lockApp) }

    /// Whether the device can check its owner at all; without a passcode there is nothing to lock with.
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func lock() {
        if Self.isEnabled { isLocked = true }
    }

    func unlock() async {
        guard isLocked, !authenticating else { return }
        guard Self.isAvailable else { isLocked = false; return }
        authenticating = true
        defer { authenticating = false }
        if await Self.authenticate(reason: "Unlock Fir") { isLocked = false }
    }

    static func authenticate(reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// Covers the browser while locked, and in the app switcher while the lock is on.
struct LockScreen: View {
    let lock: AppLock

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Text("Fir is Locked").font(.brandHeading(.title3))
            if lock.isLocked {
                Button("Unlock") { Task { await lock.unlock() } }
                    .buttonStyle(.glassProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThickMaterial)
        .ignoresSafeArea()
    }
}
