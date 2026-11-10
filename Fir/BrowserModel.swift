import SwiftUI
import WebKit

/// One tab, backed by its own WKWebView that lives as long as the tab, as in Safari. Page state is
/// mirrored from the web view through KVO so SwiftUI can observe it.
@MainActor
@Observable
final class BrowserTab: NSObject, Identifiable {
    let id: UUID
    @ObservationIgnored let webView: WKWebView
    private(set) var snapshot: UIImage?
    /// The Zen workspace this tab is in; nil for this iPhone's own tabs.
    private(set) var spaceID: String?
    /// The folder of this iPhone's own tabs it is in.
    var localFolderID: LocalFolder.ID?
    /// The pin of this iPhone's tabs it stands for; the pin outlives the tab.
    var localPinID: LocalPin.ID?

    private(set) var pageURL: URL?
    struct LoadFailure {
        let url: URL?
        let message: String
    }
    /// The last load failed and nothing replaced it. WebKit shows no error page of its own.
    private(set) var loadFailure: LoadFailure?
    private(set) var pageTitle = ""
    private(set) var isLoading = false
    /// The web view shows this page's content; false for a tab restored at launch until it loads, or
    /// after its content process died. Until then its saved snapshot stands in.
    private(set) var hasPainted = false
    private(set) var estimatedProgress = 0.0
    /// What shows around the page while WebKit's swipe moves it, so a hard flick shows no other colour.
    private(set) var pageBackground: UIColor?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// The page looks like an article, so the bar offers Reader, as Safari and Lens do.
    private(set) var isReaderable = false
    /// Set when a page of a site marked "Always Use Reader" finishes; the browser shows its reader.
    var readerRequest: URL?
    /// Vertical scroll offset, for collapsing the bar.
    private(set) var scrollY: CGFloat = 0
    /// A finger is on the page; the bar settles only once it lifts and the scroll stops.
    private(set) var isTouching = false
    /// Where a blank tab's start page last came to rest, for its card and transitions.
    var startPageOffset: CGFloat = 0
    /// Where it is now, mid-glide too; not observed, as it changes every frame of a scroll.
    @ObservationIgnored var liveStartPageOffset: CGFloat = 0

    /// A restored tab keeps its address here until first shown, so launch doesn't load every page.
    private var pendingURL: URL?
    /// pageURL stays nil until the first navigation commits; a save in that window must not lose the address.
    private var requestedURL: URL?
    private let restoredTitle: String?
    private var lastCrash: Date?
    /// The plain address HTTPS-Only last sent to https, so a failure there can offer it back.
    @ObservationIgnored private var upgradedFrom: URL?
    @ObservationIgnored private var upgradeTimeout: Task<Void, Never>?
    /// Dialogs since the page committed; see `mayShowDialog`.
    @ObservationIgnored private var dialogsThisPage = 0
    @ObservationIgnored private var lastTap = Date.distantPast
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// What each page in this tab's history looked like when it was left, for the swipe between them.
    @ObservationIgnored let pageImages = NSMapTable<WKBackForwardListItem, UIImage>.weakToStrongObjects()

    /// Keeps the page being left, as WebKit does for its own edge swipe. Only the experimental swipe
    /// uses it, and each is a full-screen snapshot held up before the navigation starts.
    func rememberPage() async {
        guard SwipeAnywhere.isEnabled, let item = webView.backForwardList.currentItem, webView.bounds.width > 0 else { return }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        if let image = try? await webView.takeSnapshot(configuration: config) { pageImages.setObject(image, forKey: item) }
    }
    /// When the tab was last in front, for archiving and clearing unused tabs.
    @ObservationIgnored var lastViewed = Date.now
    /// Kept at the front of the deck and never archived, as Zen's pinned tabs are.
    var isPinned = false
    /// The Zen records this tab's pin and "Add to Essentials" uploaded; nil when kept on this iPhone only.
    @ObservationIgnored var zenPinID: String?
    var zenEssentialID: String?
    /// Stands for a tab of a Zen folder (its record is `zenPinID`): Fir adds and drops it as Zen does,
    /// and closing it only unloads it, as closing a pinned tab does in Zen.
    private(set) var fromZenFolder = false
    /// Opens windows the page asks for (target=_blank, window.open) as tabs.
    @ObservationIgnored weak var model: BrowserModel?

    init(url: URL? = nil, spaceID: String? = nil, dataStore: WKWebsiteDataStore = .default()) {
        let url = url.flatMap { Self.isLoadable($0) ? $0 : nil }
        id = UUID()
        self.spaceID = spaceID
        restoredTitle = nil
        requestedURL = url
        webView = Self.makeWebView(dataStore: dataStore)
        super.init()
        observe()
        if let url { webView.load(URLRequest(url: url)) }
    }

    /// A window the page opened: WebKit hands over the configuration it must be created with.
    init(popupWith configuration: WKWebViewConfiguration, spaceID: String?) {
        id = UUID()
        self.spaceID = spaceID
        restoredTitle = nil
        let webView = WKWebView(frame: .zero, configuration: configuration)
        ContentBlocker.shared.attach(webView, addRules: false)
        self.webView = Self.configure(webView)
        super.init()
        observe()
    }

    init(restoring saved: SessionStore.Tab) {
        id = saved.id
        spaceID = saved.spaceID
        pendingURL = saved.url
        restoredTitle = saved.title
        lastViewed = saved.lastViewed ?? .now
        isPinned = saved.pinned ?? false
        zenPinID = saved.zenPinID
        zenEssentialID = saved.zenEssentialID
        fromZenFolder = saved.zenFolder ?? false
        localFolderID = saved.localFolder
        localPinID = saved.localPin
        webView = Self.makeWebView(dataStore: .default())
        super.init()
        snapshot = SessionStore.loadSnapshot(for: saved.id)
        observe()
    }

    /// A Zen folder's tab, unloaded until first shown, like a tab restored at launch.
    /// `id` is kept when one replaces its own unloaded tab, so the deck doesn't take it for a new card.
    init(zenFolderTab zenTab: ZenWorkspaces.Tab, url: URL, spaceID: String, id: UUID = UUID()) {
        self.id = id
        self.spaceID = spaceID
        pendingURL = url
        restoredTitle = zenTab.title
        isPinned = true
        zenPinID = zenTab.id
        fromZenFolder = true
        webView = Self.makeWebView(dataStore: .default())
        super.init()
        observe()
    }

    /// Opened at some point, not just standing in for its Zen folder tab.
    var wasOpened: Bool { pendingURL == nil || snapshot != nil }

    /// Into a Zen workspace, from this iPhone's own tabs: both use the default data store, so the page stays.
    func move(to space: String?) { spaceID = space }

    /// Its folder is gone from Zen while it is in front: it stays, as an ordinary tab.
    func leaveZenFolder() { fromZenFolder = false }

    /// Put in a Zen folder as the tab record `id`, pinned there as Zen's folder tabs are.
    func joinZenFolder(as id: String) {
        zenPinID = id
        isPinned = true
        fromZenFolder = true
    }

    /// Private tabs leave nothing on disk: not their session, snapshots or site icons.
    var isPrivate: Bool { spaceID == BrowserModel.privateSpace }

    private static func makeWebView(dataStore: WKWebsiteDataStore) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        // Extensions never see private tabs.
        if dataStore.isPersistent { config.webExtensionController = ExtensionManager.shared.controller }
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.userContentController.addUserScript(Self.pictureInPictureReturn)
        let webView = WKWebView(frame: .zero, configuration: config)
        ContentBlocker.shared.attach(webView)
        PasswordAutofill.shared.attach(webView)
        return configure(webView)
    }

    /// A video that went picture in picture comes back into the page when the page shows again, as in
    /// Safari; WebKit leaves that to the app. In every frame, so embedded players come back too.
    static let pictureInPictureReturn = WKUserScript(source: """
        document.addEventListener('visibilitychange', () => {
          if (document.visibilityState !== 'visible') return;
          for (const video of document.querySelectorAll('video')) {
            if (video.webkitPresentationMode === 'picture-in-picture') video.webkitSetPresentationMode('inline');
          }
          if (document.pictureInPictureElement) document.exitPictureInPicture().catch(() => {});
        });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    private static func configure(_ webView: WKWebView) -> WKWebView {
        webView.allowsBackForwardNavigationGestures = true
        SwipeAnywhere.attach(to: webView)
        webView.isFindInteractionEnabled = true
        // Insets are set explicitly as obscured insets (see WebHost); no automatic adjustment on top.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    private func observe() {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        webView.addGestureRecognizer(tap)
        webView.scrollView.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
        observations = [
            webView.observe(\.url) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    // A cross-origin URL may still be loading under the old page, which could fake it; didCommit sets it.
                    guard let self, Self.sameOrigin(self.pageURL, web.url) else { return }
                    self.pageURL = web.url
                }
            },
            webView.observe(\.title) { [weak self] web, _ in MainActor.assumeIsolated { self?.pageTitle = web.title ?? "" } },
            webView.observe(\.isLoading) { [weak self] web, _ in MainActor.assumeIsolated { self?.isLoading = web.isLoading } },
            webView.observe(\.underPageBackgroundColor, options: [.initial]) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    web.backgroundColor = web.underPageBackgroundColor
                    self?.pageBackground = web.underPageBackgroundColor
                }
            },
            webView.observe(\.estimatedProgress) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.estimatedProgress = web.estimatedProgress }
            },
            webView.observe(\.canGoBack) { [weak self] web, _ in MainActor.assumeIsolated { self?.canGoBack = web.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.canGoForward = web.canGoForward }
            },
            webView.scrollView.observe(\.contentOffset) { [weak self] scroll, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scrollY = scroll.contentOffset.y + scroll.adjustedContentInset.top
                    self.scheduleIdleSnapshot()
                }
            },
        ]
    }

    @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
        let touching = pan.state == .began || pan.state == .changed
        if touching != isTouching { isTouching = touching }
    }

    var url: URL? { pageURL ?? pendingURL ?? requestedURL }

    /// Scheme, host and port, with default ports filled in.
    nonisolated static func sameOrigin(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b, let scheme = a.scheme?.lowercased(), scheme == b.scheme?.lowercased() else { return false }
        func port(_ url: URL) -> Int? { url.port ?? ["http": 80, "https": 443][scheme] }
        return a.host()?.lowercased() == b.host()?.lowercased() && port(a) == port(b)
    }

    var title: String {
        if !pageTitle.isEmpty { return pageTitle }
        if pageURL == nil, let restoredTitle, !restoredTitle.isEmpty { return restoredTitle }
        return url?.host() ?? "New Tab"
    }

    /// Addresses only a page may reach: from a tab of Zen's or a link in Reader they would run as a page.
    private static func isLoadable(_ url: URL) -> Bool {
        !["about", "data", "blob", "file", "javascript"].contains(url.scheme?.lowercased() ?? "")
    }

    @objc private func tapped() { lastTap = .now }

    func stopUpgrade() {
        upgradeTimeout?.cancel()
        upgradeTimeout = nil
        upgradedFrom = nil
    }

    /// Hidden tabs stay quiet, and a page gets a few dialogs per load: `while (true) alert(1)` traps the app.
    private func mayShowDialog() -> Bool {
        guard model?.selectedID == id, dialogsThisPage < 5, !(isPrivate && model?.privateLocked == true) else { return false }
        dialogsThisPage += 1
        return true
    }

    private func dialogHost(_ frame: WKFrameInfo) -> String {
        frame.securityOrigin.host.isEmpty ? pageURL?.host() ?? "" : frame.securityOrigin.host
    }

    /// A page that never loaded has nothing for WebKit to reload.
    func reload() {
        if pageURL == nil, let url { load(url) } else { webView.reload() }
    }

    func retryFailedLoad() {
        guard let url = loadFailure?.url else { return }
        load(url)
    }

    func dismissLoadFailure() { loadFailure = nil }

    func load(_ url: URL) {
        guard Self.isLoadable(url) else { return }
        stopUpgrade()
        loadFailure = nil
        requestedURL = url
        pendingURL = nil
        webView.load(URLRequest(url: url))
    }

    func loadIfNeeded() {
        guard let pendingURL, Self.isLoadable(pendingURL) else { return }
        // Kept until the load commits: a failed or slow one otherwise left the tab with no address at all.
        requestedURL = pendingURL
        self.pendingURL = nil
        webView.load(URLRequest(url: pendingURL))
    }

    /// What transitions animate in place of the live page: a copy of what is on screen right now, made
    /// by the render server. Instant; rasterizing the page here cost 30-45 ms, five frames at 120 Hz.
    func liveSnapshot() -> UIView? {
        guard webView.window != nil, !webView.isHidden, webView.bounds.width > 0, url != nil else { return nil }
        return webView.snapshotView(afterScreenUpdates: false)
    }

    @ObservationIgnored private var idleSnapshot: Task<Void, Never>?

    /// Keeps the saved image current after scrolling, for a quit without a transition. Waits for idle:
    /// starting a snapshot costs the main thread about 15 ms, two frames at 120 Hz.
    private func scheduleIdleSnapshot() {
        idleSnapshot?.cancel()
        idleSnapshot = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            idleSnapshot = nil
            guard webView.window != nil, !webView.isHidden else { return }
            refreshSnapshot()
        }
    }

    /// Like Safari, a page leaving the screen stops its momentum; otherwise it scrolled on under the
    /// deck and reopened somewhere other than its card. A bounce settles at the edge.
    func stopScrolling() {
        let scroll = webView.scrollView
        guard scroll.isDecelerating else { return }
        let top = -scroll.adjustedContentInset.top
        let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let y = min(max(scroll.contentOffset.y, top), bottom)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
    }

    /// One colour edge to edge, or transparent: shrunk to 16x16, no pixel differs from the first.
    /// A real page differs somewhere; text alone shifts its cells by several levels.
    nonisolated static func isBlank(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return true }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        if stride(from: 3, to: pixels.count, by: 4).allSatisfy({ pixels[$0] == 0 }) { return true }
        let first = pixels.prefix(4)
        return stride(from: 0, to: pixels.count, by: 4).allSatisfy { i in
            zip(pixels[i..<i + 4], first).allSatisfy { abs(Int($0) - Int($1)) < 3 }
        }
    }

    /// Refreshes the deck card's image. WebKit renders it in its own process, so the main thread and
    /// any running animation are never held up.
    func refreshSnapshot() {
        idleSnapshot?.cancel()
        idleSnapshot = nil
        guard webView.bounds.width > 0, url != nil else { return }
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.afterScreenUpdates = false
        config.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            // On the phone WebKit sometimes hands back only the page's background, which turned the
            // card black or white; the last good image stays instead.
            guard let self, let image, !Self.isBlank(image) else { return }
            snapshot = image
            guard !isPrivate else { return }
            let id = id
            Task.detached(priority: .utility) {
                if let jpeg = image.jpegData(compressionQuality: 0.8) { SessionStore.saveSnapshot(jpeg, for: id) }
            }
        }
    }
}

extension BrowserTab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        model?.openPopup(from: self, configuration: configuration)
    }

    /// Safari's first two link actions, ahead of WebKit's own (open, copy, share).
    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo)
        async -> UIContextMenuConfiguration? {
        guard let url = elementInfo.linkURL, let model else { return nil }
        let spaceID = spaceID
        let store = webView.configuration.websiteDataStore
        // The page in a small window, as Safari shows it, with where the link really ends up.
        return UIContextMenuConfiguration(identifier: nil, previewProvider: {
            LinkPreviewController(url: url, dataStore: store)
        }) { suggested in
            let newTab = UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { _ in
                model.openInBackground(url, in: spaceID)
            }
            let privateTab = UIAction(title: "Open in Private Tab", image: UIImage(systemName: "eyes")) { _ in
                model.openInBackground(url, in: BrowserModel.privateSpace)
            }
            return UIMenu(children: [UIMenu(options: .displayInline, children: [newTab, privateTab])] + suggested)
        }
    }

    /// Tapping the preview opens the page it reached, redirects already followed.
    func webView(_ webView: WKWebView, contextMenuForElement elementInfo: WKContextMenuElementInfo,
                 willCommitWithAnimator animator: any UIContextMenuInteractionCommitAnimating) {
        guard let url = (animator.previewViewController as? LinkPreviewController)?.currentURL
                ?? elementInfo.linkURL else { return }
        animator.addCompletion { [weak self] in self?.load(url) }
    }

    func webViewDidClose(_ webView: WKWebView) {
        model?.close(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        guard mayShowDialog() else { return }
        await PageDialog.present(message, host: dialogHost(frame), cancel: nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard mayShowDialog() else { return false }
        return await PageDialog.present(message, host: dialogHost(frame), cancel: "Cancel") != nil
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard mayShowDialog() else { return nil }
        return await PageDialog.present(prompt, host: dialogHost(frame), cancel: "Cancel", field: defaultText ?? "")
    }
}

extension BrowserTab {
    /// Also run after in-page navigation: sites like meduza.io open articles without loading a page.
    func checkReaderable() async {
        isReaderable = (try? await webView.evaluateJavaScript(Self.readerableCheck)) as? Bool ?? false
    }

    /// Article test, stricter than Mozilla's isProbablyReaderable, which passed search results and short
    /// pages: one block must hold 1,200 characters in 3 real paragraphs. Paragraphs in an article or main
    /// element count even when folded away, as on mobile Wikipedia; search result pages never qualify.
    static let readerableCheck = """
        (() => {
          if (/[?&](q|query|search|text|p)=/.test(location.search)) return false;
          const blocks = new Map();
          for (const p of document.querySelectorAll('p')) {
            if (p.closest('nav, header, footer, aside, form, li')) continue;
            const main = p.closest('article, main, [role=main]');
            if (!main && !p.offsetParent) continue;
            const length = p.textContent.trim().length;
            if (length < 80) continue;
            const key = main || p.parentElement;
            const block = blocks.get(key) || { text: 0, count: 0 };
            block.text += length;
            block.count += 1;
            blocks.set(key, block);
          }
          for (const block of blocks.values()) {
            if (block.text >= 1200 && block.count >= 3) return true;
          }
          return false;
        })()
        """
}

extension BrowserTab: UIGestureRecognizerDelegate {
    /// The tap is only noted, beside whatever the web view does with it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

extension BrowserTab: WKNavigationDelegate {
    /// Links to other apps (mail, phone, App Store) go to iOS, as in Safari; WebKit can't load them.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload {
            guard navigationAction.targetFrame?.isMainFrame != false,
                  await askToDownload(navigationAction.request.url?.lastPathComponent) else { return (.cancel, preferences) }
            return (.download, preferences)
        }
        // Another page was asked for, so the wait for an upgraded one is over.
        if navigationAction.targetFrame?.isMainFrame != false, navigationAction.navigationType != .other { stopUpgrade() }
        if navigationAction.targetFrame?.isMainFrame == true { await rememberPage() }
        // The site's own settings from the page sheet: desktop layout and ad blocking.
        if navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url {
            let site = SiteSettings.shared.entry(for: url, isPrivate: isPrivate)
            preferences.preferredContentMode = site.desktop ? .desktop : .mobile
            if #available(iOS 27.0, *) {
                preferences.globalPrivacyControlEnabled = UserDefaults.standard.bool(forKey: SettingsKey.globalPrivacyControl, default: true)
            }
            if #available(iOS 26.4, *), isPrivate, UserDefaults.standard.bool(forKey: SettingsKey.hardenPrivateTabs) {
                preferences.securityRestrictionMode = .maximizeCompatibility
            }
            ContentBlocker.shared.setBlocking(site.blockAds, for: webView)
        }
        if navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url,
           let secure = HTTPSOnly.upgrade(url) {
            // Back here on its own upgrade: the site sent https to http, so it has no https to give.
            if upgradedFrom == url {
                Task { await offerInsecure(url) }
                return (.cancel, preferences)
            }
            upgradedFrom = url
            Task { webView.load(URLRequest(url: secure)) }
            // A site with nothing on port 443 never answers, and WebKit ignores the request's timeout.
            upgradeTimeout?.cancel()
            upgradeTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self, upgradedFrom == url else { return }
                self.webView.stopLoading()
                await offerInsecure(url)
            }
            return (.cancel, preferences)
        }
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
              !["http", "https", "about", "data", "blob", "file", "javascript"].contains(scheme) else {
            return (.allow, preferences)
        }
        // Like Safari: only the page itself may hand off, after asking; a tapped call or draft link
        // skips the question, since iOS confirms calls and drafts need a tap to send.
        // No target frame is a new window, decided for the frame that opened it.
        guard navigationAction.targetFrame?.isMainFrame ?? navigationAction.sourceFrame.isMainFrame else { return (.cancel, preferences) }
        let quiet = ["tel", "facetime", "facetime-audio", "mailto", "sms"].contains(scheme)
        // WebKit reports a scripted click as a link click too, so a real tap is checked as well.
        if !(quiet && navigationAction.navigationType == .linkActivated && Date.now.timeIntervalSince(lastTap) < 1) {
            guard mayShowDialog(), await PageDialog.present("Open this page in another app?", host: pageURL?.host() ?? scheme,
                                           cancel: "Cancel", confirm: "Open") != nil else { return (.cancel, preferences) }
        }
        await UIApplication.shared.open(url)
        return (.cancel, preferences)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pageURL = webView.url
        stopUpgrade()
        loadFailure = nil
        dialogsThisPage = 0
        isReaderable = false
        webView.pageZoom = SiteSettings.shared.entry(for: webView.url, isPrivate: isPrivate).zoom
    }

    /// Files the page can't show, or sends as attachments, are downloaded instead.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        let isAttachment = disposition?.lowercased().hasPrefix("attachment") == true
        if navigationResponse.canShowMIMEType, !isAttachment { return .allow }
        stopUpgrade()
        guard navigationResponse.isForMainFrame,
              await askToDownload(navigationResponse.response.suggestedFilename) else { return .cancel }
        return .download
    }

    private func askToDownload(_ name: String?) async -> Bool {
        guard mayShowDialog() else { return false }
        return await PageDialog.present("Do you want to download \"\(name ?? "this file")\"?", host: pageURL?.host() ?? "",
                                        cancel: "Cancel", confirm: "Download") != nil
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await checkReaderable() }
        if SiteSettings.shared.entry(for: webView.url, isPrivate: isPrivate).reader { readerRequest = webView.url }
        // Finishing comes just before the first paint.
        if !hasPainted {
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                hasPainted = true
            }
        }
        webView.scrollView.refreshControl?.endRefreshing()
        // Keeps the card current even for tabs never sent back to the deck before quitting. Finishing
        // the load comes before the first paint, so give it a moment or the snapshot is blank.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            refreshSnapshot()
        }
        if !isPrivate {
            Task { await adoptPageIcons() }
            if let url = webView.url {
                let title = webView.title
                Task.detached(priority: .utility) { HistoryStore.shared?.recordVisit(url, title: title) }
            }
        }
    }

    private func adoptPageIcons() async {
        let script = "Array.from(document.querySelectorAll('link[rel*=icon]')).map(l => [l.rel, l.href, l.getAttribute('sizes') || ''])"
        guard let host = webView.url?.host(),
              let rows = try? await webView.evaluateJavaScript(script) as? [[String]] else { return }
        let links = rows.filter { $0.count == 3 }.map { (rel: $0[0], href: $0[1], sizes: $0[2].isEmpty ? nil : $0[2]) }
        await Favicons.shared.adopt(links, host: host)
    }

    /// Like Safari, reload when the content process dies; a second crash within 10 s is left alone.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        webView.scrollView.refreshControl?.endRefreshing()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        webView.scrollView.refreshControl?.endRefreshing()
        // Not a replaced or cancelled load: those say nothing about the site.
        let failure = error as NSError
        guard failure.domain == NSURLErrorDomain, failure.code != NSURLErrorCancelled else { return }
        let plain = upgradedFrom
        stopUpgrade()
        if let plain, HTTPSOnly.isSecureFailure(error) {
            Task { await offerInsecure(plain, remember: !HTTPSOnly.isCertificateFailure(error)) }
        } else {
            loadFailure = LoadFailure(url: failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? url, message: failure.localizedDescription)
        }
    }

    /// HTTPS-Only couldn't reach the site securely: asks before opening it over plain HTTP, as in Lens.
    private func offerInsecure(_ url: URL, remember: Bool = true) async {
        upgradedFrom = nil
        guard let host = url.host(), await PageDialog.present(
            "This site doesn't support a secure connection. Anything you send could be seen by others on the network.",
            host: host, cancel: "Cancel", confirm: "Continue") != nil else {
            loadFailure = LoadFailure(url: url, message: "This site doesn't support a secure connection.")
            return
        }
        HTTPSOnly.allow(host, permanently: remember && !isPrivate)
        webView.load(URLRequest(url: url))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        hasPainted = false
        if let lastCrash, Date.now.timeIntervalSince(lastCrash) < 10 { return }
        lastCrash = .now
        webView.reload()
    }
}

@MainActor
@Observable
final class BrowserModel {
    private(set) var tabs: [BrowserTab] {
        didSet { for tab in tabs { tab.model = self } }
    }
    var selectedID: BrowserTab.ID? {
        // Leaving a tab is its last view, as is arriving at one.
        didSet {
            guard oldValue != selectedID else { return }
            for tab in tabs where tab.id == oldValue || tab.id == selectedID { tab.lastViewed = .now }
        }
    }
    /// The workspace the deck shows and new tabs go into; nil for this iPhone's own tabs.
    var space: String? {
        // Leaving Private locks it, as in Yab: coming back asks for Face ID. Not while a private page is
        // still in front: a regular new tab from it moves here first, and the lock closed its search.
        didSet {
            if oldValue == Self.privateSpace, space != Self.privateSpace, !selected.isPrivate { lockPrivate() }
        }
    }
    static let privateSpace = "private"
    /// Private tabs are hidden behind Face ID until unlocked.
    private(set) var privateLocked = false
    @ObservationIgnored private var unlockingPrivate = false
    /// Shared by all private tabs, like Safari; dropped with the last one so the next starts clean.
    @ObservationIgnored private var privateStore: WKWebsiteDataStore?
    /// Set from outside the view tree (the widget's link, a quick action on the icon); the root view
    /// opens new-tab search and clears it.
    var searchRequested: SearchRequest?
    /// Set as the search sheet leaves; its question's sheet can only rise once that one has gone.
    var intelligenceRequest: IntelligenceSearchRequest?
    enum SearchRequest { case tab, privateTab }
    /// Counts links opened from other apps; the root view closes search on each so the page shows.
    private(set) var linksOpened = 0

    /// A tab closed on this iPhone, newest first; private tabs leave none.
    struct ClosedTab: Codable, Identifiable {
        var id = UUID()
        let url: URL
        let title: String
        let spaceID: String?
    }

    private(set) var recentlyClosed: [ClosedTab] = {
        guard let data = UserDefaults.standard.data(forKey: closedKey) else { return [] }
        return (try? JSONDecoder().decode([ClosedTab].self, from: data)) ?? []
    }()

    private static let closedKey = "recentlyClosedTabs"

    init() {
        let session = SessionStore.load()
        tabs = session?.tabs.map(BrowserTab.init(restoring:)) ?? []
        localFolders = session?.localFolders ?? []
        localPins = session?.localPins ?? []
        if tabs.isEmpty { tabs = [BrowserTab()] }
        selectedID = tabs.contains { $0.id == session?.selectedID } ? session?.selectedID : tabs.last?.id
        space = selected.spaceID
        searchRequested = UserDefaults.standard.bool(forKey: SettingsKey.keyboardAtLaunch) ? .tab : nil
        // didSet doesn't run in an initializer.
        for tab in tabs { tab.model = self }
        // Pinned before pins outlived their tabs.
        for tab in tabs where tab.isPinned && tab.spaceID == nil && tab.localPinID == nil {
            if let url = tab.url { tab.localPinID = localPin(for: url, title: tab.title) }
        }
        // Tabs left unviewed while Fir was closed go at launch, not only on the next return to it.
        sweepIdleTabs()
    }

    /// Writes off the main thread: on it, the file write cost a frame of the deck transition.
    func save() {
        pruneLocalFolders()
        let session = SessionStore.Session(
            tabs: tabs.filter { !$0.isPrivate }.map {
                SessionStore.Tab(id: $0.id, url: $0.url, title: $0.title, spaceID: $0.spaceID, lastViewed: $0.lastViewed,
                                 pinned: $0.isPinned, zenPinID: $0.zenPinID,
                                 zenEssentialID: $0.zenEssentialID, zenFolder: $0.fromZenFolder ? true : nil,
                                 localFolder: $0.localFolderID, localPin: $0.localPinID)
            },
            selectedID: selectedID,
            localFolders: localFolders,
            localPins: localPins
        )
        Self.saveQueue.async { SessionStore.save(session) }
    }

    /// Serial, so an older session never overwrites a newer one.
    private static let saveQueue = DispatchQueue(label: "Fir.session", qos: .utility)

    var selected: BrowserTab {
        tabs.first { $0.id == selectedID } ?? tabs[0]
    }

    /// The tabs of the deck's workspace, in deck order.
    var spaceTabs: [BrowserTab] { tabs(in: space) }

    func tabs(in space: String?) -> [BrowserTab] {
        let all = tabs.filter { $0.spaceID == space }
        // Folders lead, in Zen's order (as at the top of Zen's sidebar) or the order they were made in.
        let place: (BrowserTab) -> Int?
        if let space {
            guard let folders = zenFolders[space] else { return all }
            let rank = Dictionary(folders.flatMap(\.tabs).enumerated().map { ($1.id, $0) }) { first, _ in first }
            place = { $0.fromZenFolder ? $0.zenPinID.flatMap { rank[$0] } : nil }
        } else {
            guard !localFolders.isEmpty else { return all }
            let rank = Dictionary(uniqueKeysWithValues: localFolders.enumerated().map { ($1.id, $0) })
            place = { $0.localFolderID.flatMap { rank[$0] } }
        }
        // Stable: within a folder, tabs keep the order they joined in.
        let placed = all.enumerated().compactMap { offset, tab in place(tab).map { ($0, offset, tab) } }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
        return placed + all.filter { place($0) == nil }
    }

    /// Zen's folders per workspace, as last synced.
    private(set) var zenFolders: [String: [ZenWorkspaces.Folder]] = [:]

    /// Folders of this iPhone's own tabs; Zen never sees them until one is moved into a workspace.
    private(set) var localFolders: [LocalFolder] = []

    /// The folder a tab is in, in Zen or on this iPhone.
    func folder(of tab: BrowserTab) -> DeckFolder? {
        if let local = tab.localFolderID, let folder = localFolders.first(where: { $0.id == local }) {
            return DeckFolder(id: folder.id.uuidString, name: folder.name, local: folder.id)
        }
        return zenFolder(of: tab).map { DeckFolder(id: $0.id, name: $0.name, local: nil) }
    }

    /// The Zen folder a tab stands in for, if any.
    private func zenFolder(of tab: BrowserTab) -> ZenWorkspaces.Folder? {
        guard tab.fromZenFolder, let id = tab.zenPinID, let space = tab.spaceID else { return nil }
        return zenFolders[space]?.first { $0.tabs.contains { $0.id == id } }
    }

    /// A new folder of this iPhone's tabs, holding `tab`.
    func createLocalFolder(named name: String, with tab: BrowserTab) {
        let folder = LocalFolder(name: name)
        localFolders.append(folder)
        tab.localFolderID = folder.id
        save()
    }

    func addToLocalFolder(_ tab: BrowserTab, _ folder: LocalFolder.ID) {
        tab.localFolderID = folder
        save()
    }

    /// Out of its folder; a folder left empty goes too.
    func removeFromLocalFolder(_ tab: BrowserTab) {
        tab.localFolderID = nil
        save()
    }

    /// The folder goes, its tabs stay as ordinary tabs.
    func ungroup(_ folder: LocalFolder.ID) {
        for tab in tabs where tab.localFolderID == folder { tab.localFolderID = nil }
        localFolders.removeAll { $0.id == folder }
        save()
    }

    /// Takes the folder off this iPhone's list as its tabs move into Zen; `restore` puts it back.
    func detachLocalFolder(_ folder: LocalFolder.ID) -> (LocalFolder, index: Int)? {
        guard let index = localFolders.firstIndex(where: { $0.id == folder }) else { return nil }
        return (localFolders.remove(at: index), index)
    }

    func restoreLocalFolder(_ folder: LocalFolder, at index: Int) {
        localFolders.insert(folder, at: min(index, localFolders.count))
        save()
    }

    /// Folders with no tab left go, and a tab whose folder went (say, closed then undone) leaves it.
    private func pruneLocalFolders() {
        let used = Set(tabs.compactMap(\.localFolderID))
        localFolders.removeAll { !used.contains($0.id) }
        let kept = Set(localFolders.map(\.id))
        for tab in tabs where tab.localFolderID.map({ !kept.contains($0) }) == true { tab.localFolderID = nil }
    }

    /// Keeps one tab per Zen folder tab, in the folder's workspace: adds the new, drops those Zen no longer
    /// has. One that was opened stays, as an ordinary tab, rather than take a page away. Nil (signed out,
    /// workspaces off) drops them all.
    func mirror(_ zen: ZenWorkspaces?) {
        let folders = zen?.foldersBySpace ?? [:]
        var wanted: [String: (tab: ZenWorkspaces.Tab, url: URL, space: String)] = [:]
        for (space, list) in folders {
            for zenTab in list.flatMap(\.tabs) {
                if let url = zenTab.url { wanted[zenTab.id] = (zenTab, url, space) }
            }
        }
        var changed = false
        for tab in tabs where tab.fromZenFolder {
            if let id = tab.zenPinID, wanted[id]?.space == tab.spaceID { continue }
            changed = true
            if tab.wasOpened || tab.id == selectedID { tab.leaveZenFolder() } else { discard(tab) }
        }
        let have = Set(tabs.filter(\.fromZenFolder).compactMap(\.zenPinID))
        for (id, entry) in wanted.sorted(by: { $0.key < $1.key }) where !have.contains(id) {
            tabs.append(BrowserTab(zenFolderTab: entry.tab, url: entry.url, spaceID: entry.space))
            changed = true
        }
        zenFolders = folders
        if changed { save() }
    }

    /// Closing a folder's tab unloads it, as in Zen: a fresh unloaded one takes its place. Closed from its
    /// page the neighbour comes to the front; in the deck the card stays, so the deck doesn't move.
    private func unload(_ tab: BrowserTab, to zenTab: ZenWorkspaces.Tab, url: URL, inPlace: Bool) {
        guard let space = tab.spaceID, let position = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let siblings = tabs(in: space)
        let index = siblings.firstIndex { $0.id == tab.id } ?? 0
        let fresh = BrowserTab(zenFolderTab: zenTab, url: url, spaceID: space, id: tab.id)
        tabs[position] = fresh
        tab.stopUpgrade()
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        if selectedID == tab.id {
            let others = siblings.filter { $0.id != tab.id }
            selectedID = inPlace || others.isEmpty ? fresh.id : others[min(index, others.count - 1)].id
            // Closed from its page with nothing to go to: it stays in front, so it can't stay blank.
            if !inPlace, others.isEmpty { fresh.loadIfNeeded() }
        }
        SessionStore.deleteSnapshot(for: tab.id)
        save()
        unloaded = Unloaded(folder: zenFolder(of: fresh)?.name ?? "its folder")
    }

    /// Says a folder's tab was unloaded, not closed: its card stays in the folder, so "closed" would mislead.
    struct Unloaded: Equatable {
        var id = UUID()
        let folder: String
    }

    var unloaded: Unloaded?

    /// Makes the tab the last card of its workspace's deck, as in Yab: the deck opens on what you just
    /// left, with older tabs stacked to its left.
    func moveToEnd(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }), index != tabs.count - 1 else { return }
        tabs.append(tabs.remove(at: index))
        save()
    }

    /// A pinned tab is never archived. It keeps its place in the deck like any other tab: held at the front,
    /// a page left from it shrank onto a card the next one covered.
    func setPinned(_ pinned: Bool, _ tab: BrowserTab) {
        guard tab.isPinned != pinned else { return }
        tab.isPinned = pinned
        if pinned, tab.spaceID == nil, let url = tab.url {
            tab.localPinID = localPin(for: url, title: tab.title)
        } else if !pinned, let id = tab.localPinID {
            unpin(id)
        }
        save()
    }

    /// This iPhone's pins, listed on the start page. Closing a tab leaves its pin.
    private(set) var localPins: [LocalPin] = []

    private func localPin(for url: URL, title: String) -> LocalPin.ID {
        if let pin = localPins.first(where: { $0.url == url }) { return pin.id }
        let pin = LocalPin(url: url, title: title)
        localPins.append(pin)
        return pin.id
    }

    func unpin(_ id: LocalPin.ID) {
        localPins.removeAll { $0.id == id }
        for tab in tabs where tab.localPinID == id {
            tab.localPinID = nil
            tab.isPinned = false
        }
        save()
    }

    /// Back to its tab if one is open, else in a new one that stands for the pin. A blank tab it was
    /// opened from goes, since the pin has a tab of its own.
    func open(_ pin: LocalPin, replacing blank: BrowserTab? = nil) {
        if let tab = tabs.first(where: { $0.localPinID == pin.id }) {
            select(tab)
        } else {
            let tab = BrowserTab(url: pin.url, dataStore: dataStore(for: nil))
            tab.isPinned = true
            tab.localPinID = pin.id
            tabs.append(tab)
            select(tab)
        }
        if let blank, blank.url == nil, blank.localPinID == nil { discard(blank) }
        save()
    }

    func select(_ tab: BrowserTab) {
        let leavesPrivate = selected.isPrivate && !tab.isPrivate
        selectedID = tab.id
        space = tab.spaceID
        // Selected already if it was unloaded in place, so the change of selection won't load it.
        tab.loadIfNeeded()
        if leavesPrivate { lockPrivate() }
    }

    /// A window the page opened becomes a new tab in the opener's workspace, shown at once, as in Safari.
    func openPopup(from opener: BrowserTab, configuration: WKWebViewConfiguration) -> WKWebView {
        let tab = BrowserTab(popupWith: configuration, spaceID: opener.spaceID)
        tabs.append(tab)
        select(tab)
        save()
        return tab.webView
    }

    /// A link from another app, with Fir as the default browser: a new tab in front, never private.
    func openLink(_ url: URL) {
        searchRequested = nil
        open(url, in: selected.isPrivate ? nil : selected.spaceID)
        linksOpened += 1
    }

    /// Keeps the current page in front, as Safari's "Open in New Tab" does.
    func openInBackground(_ url: URL, in space: String?) {
        tabs.append(BrowserTab(url: url, spaceID: space, dataStore: dataStore(for: space)))
        save()
    }

    /// In the workspace the deck shows.
    func open(_ url: URL?) {
        open(url, in: space)
    }

    /// In exactly that workspace; nil is this iPhone's own tabs, never "the current one", which was
    /// Private for links from other apps arriving while a private tab was in front.
    func open(_ url: URL?, in spaceID: String?) {
        let tab = BrowserTab(url: url, spaceID: spaceID, dataStore: dataStore(for: spaceID))
        tabs.append(tab)
        select(tab)
        save()
    }

    /// The tab closed last, kept whole with its history so the undo capsule can put it back.
    struct Undo {
        let tab: BrowserTab
        let index: Int
        let wasSelected: Bool
        /// The blank tab added because closing emptied the browser.
        let placeholder: BrowserTab.ID?
    }

    private(set) var undo: Undo?

    /// Selects the neighbour in the same workspace that slides into the closed tab's slot, so the
    /// deck stays put. The deck keeps showing that workspace even when it empties.
    func close(_ tab: BrowserTab, inPlace: Bool = false) {
        if let folder = zenFolder(of: tab), let zenTab = folder.tabs.first(where: { $0.id == tab.zenPinID }),
           let url = zenTab.url {
            unload(tab, to: zenTab, url: url, inPlace: inPlace)
            return
        }
        remember(tab)
        let siblings = tabs(in: tab.spaceID)
        guard let index = siblings.firstIndex(where: { $0.id == tab.id }),
              let position = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.removeAll { $0.id == tab.id }
        tab.stopUpgrade()
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        var placeholder: BrowserTab.ID?
        // Closing a regular tab must not bring up a private one, so one regular tab always remains.
        if tabs.isEmpty || (!tab.isPrivate && tabs.allSatisfy(\.isPrivate)) {
            tabs.append(BrowserTab())
            placeholder = tabs.last?.id
        }
        undo = Undo(tab: tab, index: position, wasSelected: selectedID == tab.id, placeholder: placeholder)
        endPrivateSessionIfDone()
        if selectedID == tab.id {
            let rest = tabs(in: tab.spaceID)
            let next = rest.isEmpty ? tabs.last { !$0.isPrivate } ?? tabs.last : rest[min(index, rest.count - 1)]
            selectedID = next?.id
            // Left on the emptied workspace, a page's next new tab would open there, even as private.
            if rest.isEmpty, !inPlace, let next { space = next.spaceID }
        }
        SessionStore.deleteSnapshot(for: tab.id)
        save()
    }

    private func endPrivateSessionIfDone() {
        guard !tabs.contains(where: \.isPrivate) else { return }
        privateStore = nil
        SiteSettings.shared.forgetPrivate()
        HTTPSOnly.forgetTemporary()
    }

    /// Closes every tab of a workspace, leaving one new tab if that empties the browser.
    func closeAll(in space: String?) {
        for tab in tabs(in: space) { close(tab) }
        undo = nil
    }

    /// Puts the last closed tab back where it was, history included, and drops it from Recently Closed.
    func undoClose() {
        guard let undo else { return }
        self.undo = nil
        let tab = undo.tab
        // Unpinned while it was closed.
        if let pin = tab.localPinID, !localPins.contains(where: { $0.id == pin }) {
            tab.localPinID = nil
            tab.isPinned = false
        }
        if let placeholder = undo.placeholder, tabs.count == 1, tabs[0].id == placeholder, tabs[0].url == nil {
            tabs = []
        }
        tabs.insert(tab, at: min(undo.index, tabs.count))
        if tab.isPrivate { privateStore = tab.webView.configuration.websiteDataStore }
        if undo.wasSelected { select(tab) }
        if !tab.isPrivate, recentlyClosed.first?.url == tab.url {
            recentlyClosed.removeFirst()
            storeRecentlyClosed()
        }
        // Closing deleted the saved card image; the tab still holds it.
        if let image = tab.snapshot, !tab.isPrivate {
            let id = tab.id
            Task.detached(priority: .utility) {
                if let jpeg = image.jpegData(compressionQuality: 0.8) { SessionStore.saveSnapshot(jpeg, for: id) }
            }
        }
        save()
    }

    /// The undo window has passed.
    func dropUndo() { undo = nil }

    static var locksPrivateTabs: Bool { UserDefaults.standard.bool(forKey: SettingsKey.lockPrivateTabs) }

    func lockPrivate() {
        if Self.locksPrivateTabs, tabs.contains(where: \.isPrivate) {
            privateLocked = true
            pausePrivateMedia()
        }
    }

    /// Media playing in the background shows its title on the Lock Screen, which Fir's lock doesn't cover.
    func pausePrivateMedia() {
        for tab in tabs where tab.isPrivate { tab.webView.pauseAllMediaPlayback(completionHandler: nil) }
    }

    func unlockPrivate() async {
        // The deck and the page each ask on appearing; one Face ID prompt is enough.
        guard privateLocked, !unlockingPrivate else { return }
        guard AppLock.isAvailable else { privateLocked = false; return }
        unlockingPrivate = true
        defer { unlockingPrivate = false }
        if await AppLock.authenticate(reason: "Show private tabs") { privateLocked = false }
    }

    /// Off a locked private page to this iPhone's newest tab, or a new one.
    func leavePrivate() {
        if let tab = tabs.last(where: { !$0.isPrivate }) {
            select(tab)
        } else {
            open(nil, in: nil)
        }
    }

    private(set) var archived = ArchiveStore.load()

    /// Archives and clears tabs nobody has looked at in the chosen time, as Lens does. The tab in front
    /// stays; private tabs close rather than being archived, and blank ones simply close.
    func sweepIdleTabs(now: Date = .now) {
        let archiveAfter = TabLifetime.archive.interval
        let clearAfter = TabLifetime.clear.interval
        var archiveChanged = false
        if let clearAfter, archiveAfter != nil {
            let before = archived.count
            archived.removeAll { now.timeIntervalSince($0.lastViewed) > clearAfter }
            archiveChanged = archived.count != before
        }
        guard let limit = archiveAfter ?? clearAfter else {
            if archiveChanged { ArchiveStore.save(archived) }
            return
        }
        let idle = tabs.filter { $0.id != selectedID && !$0.isPinned && now.timeIntervalSince($0.lastViewed) > limit }
        for tab in idle {
            if archiveAfter != nil, !tab.isPrivate, let url = tab.url {
                archived.append(ArchivedTab(url: url, title: tab.title, spaceID: tab.spaceID, lastViewed: tab.lastViewed))
                archiveChanged = true
            } else if archiveAfter == nil {
                remember(tab)
            }
            discard(tab)
        }
        if archiveChanged { ArchiveStore.save(archived) }
        if !idle.isEmpty { save() }
    }

    /// Opens an archived tab again in its workspace.
    func reopen(_ tab: ArchivedTab) {
        deleteArchived([tab.id])
        open(tab.url, in: tab.spaceID)
    }

    func deleteArchived(_ ids: [ArchivedTab.ID]) {
        archived.removeAll { ids.contains($0.id) }
        ArchiveStore.save(archived)
    }

    /// Takes a tab away without the undo capsule or its haptic: for tabs Fir closes on its own.
    private func discard(_ tab: BrowserTab) {
        tabs.removeAll { $0.id == tab.id }
        tab.stopUpgrade()
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        if tabs.isEmpty { tabs = [BrowserTab()] }
        endPrivateSessionIfDone()
        SessionStore.deleteSnapshot(for: tab.id)
    }

    /// Opens a closed tab again in its workspace and drops it from the list.
    func reopen(_ closed: ClosedTab) {
        recentlyClosed.removeAll { $0.id == closed.id }
        storeRecentlyClosed()
        open(closed.url, in: closed.spaceID)
    }

    private func remember(_ tab: BrowserTab) {
        guard !tab.isPrivate, let url = tab.url else { return }
        recentlyClosed.insert(ClosedTab(url: url, title: tab.title, spaceID: tab.spaceID), at: 0)
        recentlyClosed = Array(recentlyClosed.prefix(20))
        storeRecentlyClosed()
    }

    private func storeRecentlyClosed() {
        UserDefaults.standard.set(try? JSONEncoder().encode(recentlyClosed), forKey: Self.closedKey)
    }

    private func dataStore(for space: String?) -> WKWebsiteDataStore {
        guard space == Self.privateSpace else { return .default() }
        let store = privateStore ?? .nonPersistent()
        privateStore = store
        return store
    }

    func goBack() { selected.webView.goBack() }

    func goForward() { selected.webView.goForward() }

    /// Treats input with a dot and no spaces as an address, anything else as a search query.
    static func url(from input: String, engine: SearchEngine) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("."), !text.contains(" ") {
            let withScheme = text.contains("://") ? text : "https://\(text)"
            if let url = URL(string: withScheme) { return url }
        }
        return engine.url(for: text)
    }
}

/// Opens sites over HTTPS only, asking before any falls back to plain HTTP.
@MainActor
enum HTTPSOnly {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.httpsOnly, default: true) }
    /// Sites the user let load over HTTP; kept, or every restored tab of one would ask at each launch.
    private static var allowed = Set(UserDefaults.standard.stringArray(forKey: allowedKey) ?? [])
    private static let allowedKey = "httpsOnlyAllowed"

    /// Never saved: choices from private tabs, and after a bad certificate, which someone on the network can fake.
    private static var allowedForNow = Set<String>()

    static func allow(_ host: String, permanently: Bool) {
        guard permanently else {
            allowedForNow.insert(host)
            return
        }
        allowed.insert(host)
        UserDefaults.standard.set(Array(allowed), forKey: allowedKey)
    }

    static func forgetTemporary() {
        allowedForNow = []
    }

    static func isCertificateFailure(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain && [
            NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
        ].contains(error.code)
    }

    /// The https form of a plain address that should be upgraded; nil to load it as it is.
    static func upgrade(_ url: URL) -> URL? {
        guard isEnabled, url.scheme?.lowercased() == "http", let host = url.host(), !allowed.contains(host),
              !allowedForNow.contains(host),
              !isLocal(host), var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "https"
        if components.port == 80 { components.port = nil }
        return components.url
    }

    /// Failures that mean the site has no working https, not that the network is down.
    static func isSecureFailure(_ error: any Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut].contains(error.code)
    }

    /// The local network and this iPhone rarely have certificates; they stay on HTTP.
    private static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
    }
}

/// Experimental, as in Lens: a sideways swipe anywhere on a page goes back or forward, not only from the
/// screen's edge. It looks like WebKit's own edge swipe: the page follows the finger over the one it goes
/// to, drawn from the image kept when it was left. WebKit's edge swipe stays as it is.
@MainActor
final class SwipeAnywhere: NSObject, UIGestureRecognizerDelegate {
    private static let shared = SwipeAnywhere()
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.swipeAnywhere) }

    private struct Transition {
        let container: UIView
        let page: UIView
        let target: UIView
        let shade: UIView
        let back: Bool
    }

    private var transition: Transition?

    static func attach(to webView: WKWebView) {
        let pan = UIPanGestureRecognizer(target: shared, action: #selector(pan(_:)))
        pan.delegate = shared
        webView.addGestureRecognizer(pan)
    }

    @objc private func pan(_ pan: UIPanGestureRecognizer) {
        guard let webView = pan.view as? WKWebView else { return }
        let width = webView.bounds.width
        let dx = pan.translation(in: webView).x
        switch pan.state {
        case .began:
            transition = begin(on: webView, back: pan.velocity(in: webView).x > 0)
            // The page mustn't scroll under a sideways swipe.
            webView.scrollView.panGestureRecognizer.isEnabled = false
            webView.scrollView.panGestureRecognizer.isEnabled = true
        case .changed:
            guard let transition else { return }
            layout(transition, progress: transition.back ? dx / width : -dx / width, width: width)
        case .ended, .cancelled, .failed:
            guard let transition else { return }
            self.transition = nil
            let progress = transition.back ? dx / width : -dx / width
            let speed = transition.back ? pan.velocity(in: webView).x : -pan.velocity(in: webView).x
            let commit = pan.state == .ended && (progress > 0.4 || speed > 600) && progress > 0
            UIView.animate(springDuration: 0.3, bounce: 0, initialSpringVelocity: max(0, speed / width)) {
                self.layout(transition, progress: commit ? 1 : 0, width: width)
            } completion: { _ in
                guard commit else { return transition.container.removeFromSuperview() }
                if transition.back { webView.goBack() } else { webView.goForward() }
                Self.reveal(transition, over: webView)
            }
        default:
            break
        }
    }

    /// Going back the page slides off right over the previous one; going forward the next one slides in.
    private func begin(on webView: WKWebView, back: Bool) -> Transition? {
        let list = webView.backForwardList
        guard let host = webView.superview, let page = webView.snapshotView(afterScreenUpdates: false),
              let item = back ? list.backItem : list.forwardItem else { return nil }
        let container = UIView(frame: webView.frame)
        container.clipsToBounds = true
        container.isUserInteractionEnabled = false
        let image = (webView.navigationDelegate as? BrowserTab)?.pageImages.object(forKey: item)
        let target = UIImageView(image: image)
        target.contentMode = .scaleAspectFill
        target.clipsToBounds = true
        target.backgroundColor = webView.underPageBackgroundColor
        target.frame = container.bounds
        page.frame = container.bounds
        let shade = UIView(frame: container.bounds)
        shade.backgroundColor = .black
        shade.isUserInteractionEnabled = false
        // The one on top casts a shadow over the one beneath, as in Safari.
        let top: UIView = back ? page : target
        top.layer.shadowColor = UIColor.black.cgColor
        top.layer.shadowOpacity = 0.25
        top.layer.shadowRadius = 12
        top.layer.shadowPath = UIBezierPath(rect: top.bounds).cgPath
        container.addSubview(back ? target : page)
        container.addSubview(shade)
        container.addSubview(top)
        host.insertSubview(container, aboveSubview: webView)
        let transition = Transition(container: container, page: page, target: target, shade: shade, back: back)
        layout(transition, progress: 0, width: container.bounds.width)
        return transition
    }

    private func layout(_ t: Transition, progress: CGFloat, width: CGFloat) {
        let p = min(max(progress, 0), 1)
        if t.back {
            t.page.transform = CGAffineTransform(translationX: p * width, y: 0)
            t.target.transform = CGAffineTransform(translationX: -(1 - p) * width * 0.3, y: 0)
        } else {
            t.target.transform = CGAffineTransform(translationX: (1 - p) * width, y: 0)
            t.page.transform = CGAffineTransform(translationX: -p * width * 0.3, y: 0)
        }
        t.shade.alpha = 0.18 * (t.back ? 1 - p : p)
    }

    /// The image stays over the page until WebKit has drawn it, then fades.
    private static func reveal(_ t: Transition, over webView: WKWebView) {
        Task { @MainActor in
            for _ in 0..<20 where webView.isLoading { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(80))
            UIView.animate(withDuration: 0.2) { t.container.alpha = 0 } completion: { _ in t.container.removeFromSuperview() }
        }
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard Self.isEnabled, transition == nil, let pan = gesture as? UIPanGestureRecognizer,
              let webView = pan.view as? WKWebView else { return false }
        let start = pan.location(in: webView).x
        let velocity = pan.velocity(in: webView)
        // Clearly sideways, towards a page there is, and clear of the edges WebKit's own swipe uses.
        guard abs(velocity.x) > abs(velocity.y) * 2, start > 30, start < webView.bounds.width - 30 else { return false }
        return velocity.x > 0 ? webView.canGoBack : webView.canGoForward
    }

    /// Alongside the page's own gestures, so pages keep working while it watches.
    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
/// A link's page in a context menu preview, under a strip naming the host it has reached so far.
final class LinkPreviewController: UIViewController {
    private let url: URL
    private let dataStore: WKWebsiteDataStore
    private var webView: WKWebView?
    private let address = UILabel()
    private var observation: NSKeyValueObservation?

    var currentURL: URL? { webView?.url ?? url }

    init(url: URL, dataStore: WKWebsiteDataStore) {
        self.url = url
        self.dataStore = dataStore
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 0, height: 560)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isUserInteractionEnabled = false
        ContentBlocker.shared.attach(webView)
        self.webView = webView

        address.font = .preferredFont(forTextStyle: .footnote)
        address.textColor = .secondaryLabel
        address.textAlignment = .center
        address.attributedText = Self.label(url)
        let strip = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        strip.contentView.addSubview(address)

        for subview in [webView, strip] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        address.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: view.topAnchor),
            strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: 32),
            address.centerYAnchor.constraint(equalTo: strip.contentView.centerYAnchor),
            address.leadingAnchor.constraint(equalTo: strip.contentView.leadingAnchor, constant: 12),
            address.trailingAnchor.constraint(equalTo: strip.contentView.trailingAnchor, constant: -12),
            webView.topAnchor.constraint(equalTo: strip.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // Each redirect shows as it happens, so a tracking link's real destination is plain to see.
        observation = webView.observe(\.url, options: .new) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.address.attributedText = Self.label(webView.url) }
        }
        webView.load(URLRequest(url: HTTPSOnly.upgrade(url) ?? url))
    }

    private static func label(_ url: URL?) -> NSAttributedString {
        guard let url else { return NSAttributedString() }
        let text = NSMutableAttributedString()
        if url.scheme == "https", let lock = UIImage(systemName: "lock.fill") {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: lock.withTintColor(.secondaryLabel))))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: url.host() ?? url.absoluteString))
        return text
    }
}

/// A folder of this iPhone's own tabs, kept with the session.
struct LocalFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
}

/// A pinned page of this iPhone's own tabs. Zen's pins live in Zen; these have nowhere else to live.
struct LocalPin: Codable, Identifiable, Hashable {
    var id = UUID()
    let url: URL
    let title: String
}

/// A folder as the deck shows it: one of Zen's, or one of this iPhone's (`local`).
struct DeckFolder: Hashable {
    let id: String
    let name: String
    let local: LocalFolder.ID?
}
