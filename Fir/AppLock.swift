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

/// The lock screen in its own window above the scene's sheets and covers, which an overlay on the
/// browser sat under: an open Passwords sheet stayed usable behind a cancelled Face ID.
@MainActor
enum LockWindow {
    private static var window: UIWindow?
    static var isShown: Bool { window != nil }

    static func show(_ shown: Bool, lock: AppLock, tint: Color?, title: LocalizedStringKey) {
        guard shown else {
            window?.isHidden = true
            window = nil
            return
        }
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        // A keyboard already up stays above any window; it goes, or it types into the page behind.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = scene.windows.first?.overrideUserInterfaceStyle ?? .unspecified
        let host = UIHostingController(rootView: LockScreen(lock: lock, title: title).tint(tint))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        Self.window = window
    }
}

/// Covers the browser while locked, and in the app switcher while the lock is on.
struct LockScreen: View {
    let lock: AppLock
    var title: LocalizedStringKey = "Fir is Locked"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Text(title).font(.brandHeading(.title3))
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
