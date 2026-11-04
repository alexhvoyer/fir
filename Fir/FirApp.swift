import AVFoundation
import SwiftUI
import MozillaAppServices

@main
struct FirApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var account = AccountService()
    @State private var browser = BrowserModel()
    @State private var lock = AppLock()
    @AppStorage(SettingsKey.appearance) private var appearance = Appearance.system
    @AppStorage(SettingsKey.accent) private var accent = Accent.system
    @AppStorage(SettingsKey.onboardingDone) private var onboardingDone = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Rust components (NSS, HTTP) must be initialized before any FxA or sync call.
        MozillaAppServices.initialize()
        // A media app's session: page audio keeps playing in the background and when silenced by
        // the ring switch, as in Safari, and video can go picture in picture.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        Viaduct.shared.initialize(userAgent: "Fir-iOS-FxA/0.1")
        // Installs from before onboarding existed already have tabs; only a fresh one gets it.
        if SessionStore.load() != nil { UserDefaults.standard.set(true, forKey: SettingsKey.onboardingDone) }
    }

    var body: some Scene {
        WindowGroup {
            BrowserView()
                .environment(account)
                .environment(browser)
                .overlay {
                    // Also hides the page in the app switcher, where the lock hasn't engaged yet.
                    if lock.isLocked || (AppLock.isEnabled && scenePhase != .active) { LockScreen(lock: lock) }
                }
                .fullScreenCover(isPresented: Binding(get: { !onboardingDone }, set: { onboardingDone = !$0 })) {
                    OnboardingView { onboardingDone = true }
                        .environment(account)
                        .tint(accent.color)
                }
                // On the windows rather than preferredColorScheme: that left an open sheet in the old
                // theme, and going back to System kept the last explicit one.
                .onChange(of: appearance, initial: true) { Appearance.apply(appearance) }
                // The chosen accent for links, progress and selection; covers sheets too.
                .tint(accent.color)
                .task { await account.start() }
                .onAppear {
                    QuickAction.handler = { browser.searchRequested = $0 == .newPrivateTab ? .privateTab : .tab }
                }
                #if DEBUG
                .task { FrameMeter.shared.start() }
                #endif
                .task { await ContentBlocker.shared.start() }
                .task { await ExtensionManager.shared.start(browser: browser) }
                // Tabs sent from Zen open here, the last one in front.
                .onChange(of: account.receivedTabs, initial: true) {
                    guard !account.receivedTabs.isEmpty else { return }
                    let urls = account.receivedTabs
                    account.receivedTabs = []
                    for url in urls.dropLast() { browser.openInBackground(url, in: browser.selected.spaceID) }
                    if let last = urls.last { browser.open(last, in: browser.selected.isPrivate ? nil : browser.selected.spaceID) }
                }
                // The search widget opens firbrowser://search; web links come from other apps.
                .onOpenURL { url in
                    switch url.scheme?.lowercased() {
                    case "firbrowser" where url.host() == "search": browser.searchRequested = .tab
                    case "http", "https": browser.openLink(url)
                    default: break
                    }
                }
        }
        // Leaving the foreground is the last reliable moment before the app may be killed.
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .background:
                lock.lock()
                // The app lock already asks on return; a second Face ID prompt for private tabs would race it.
                if !AppLock.isEnabled { browser.lockPrivate() }
            case .active:
                Task { await lock.unlock() }
                browser.sweepIdleTabs()
            default: break
            }
            if scenePhase != .active { browser.save() }
        }
    }
}
