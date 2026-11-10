import AVFoundation
import CoreSpotlight
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

    private var lockCovers: Bool { lock.isLocked || (AppLock.isEnabled && scenePhase != .active) }
    /// iOS photographs the screen for the app switcher and keeps the image on disk.
    private var privateCovers: Bool { browser.selected.isPrivate && scenePhase != .active }
    private var coverTitle: LocalizedStringKey { lockCovers ? "Fir is Locked" : "Private Browsing" }

    /// Never a private tab's page, or anything while Fir is locked.
    private var handoffURL: URL? {
        guard !lockCovers, !browser.selected.isPrivate, let url = browser.selected.pageURL,
              ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

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
                    // Also hides the page in the app switcher, where the lock hasn't engaged yet. The
                    // window covers sheets; this covers the browser before the window exists.
                    if lockCovers || privateCovers { LockScreen(lock: lock, title: coverTitle) }
                }
                .onChange(of: lockCovers || privateCovers, initial: true) {
                    LockWindow.show(lockCovers || privateCovers, lock: lock, tint: accent.color, title: coverTitle)
                }
                .fullScreenCover(isPresented: Binding(get: { !onboardingDone }, set: { onboardingDone = !$0 })) {
                    OnboardingView {
                        WhatsNew.markSeen()
                        onboardingDone = true
                    }
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
                    QuickAction.requests.handler = { browser.searchRequested = $0 == .newPrivateTab ? .privateTab : .tab }
                    SystemSearch.requests.handler = { browser.openLink($0) }
                    NewTabRequest.requests.handler = { browser.searchRequested = $0 ? .privateTab : .tab }
                }
                // "Search in app" from Spotlight, with what was typed there.
                .onContinueUserActivity(CSQueryContinuationActionType) { activity in
                    if let query = activity.userInfo?[CSSearchQueryString] as? String { SystemSearch.perform(query) }
                }
                #if DEBUG
                .task {
                    // The frame meter's 120 Hz display link would itself show in the CPU reading.
                    if ProcessInfo.processInfo.environment["FIR_CPU"] != nil { CPUMeter.start() } else { FrameMeter.shared.start() }
                }
                #endif
                .task { await ContentBlocker.shared.start() }
                .task { await ExtensionManager.shared.start(browser: browser) }
                // Each Zen folder's tabs become tabs of its workspace, kept in step with Zen.
                .onChange(of: account.zenWorkspaces?.foldersBySpace, initial: true) {
                    browser.mirror(account.zenWorkspaces)
                }
                // Tabs sent from Zen open here, the last one in front.
                .onChange(of: account.receivedTabs, initial: true) {
                    guard !account.receivedTabs.isEmpty else { return }
                    let urls = account.receivedTabs
                    account.receivedTabs = []
                    for url in urls.dropLast() { browser.openInBackground(url, in: browser.selected.isPrivate ? nil : browser.selected.spaceID) }
                    if let last = urls.last { browser.openLink(last) }
                }
                // The page in front continues on the Mac, as in Safari.
                .userActivity(NSUserActivityTypeBrowsingWeb, element: handoffURL) { url, activity in
                    activity.webpageURL = url
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
                browser.pausePrivateMedia()
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
