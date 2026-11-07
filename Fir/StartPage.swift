import MozillaAppServices
import SwiftUI

/// The search sheet before anything is typed, like Safari's start page: the workspace's Zen essentials
/// and pinned tabs, the newest tabs from Zen and recent history. A private tab shows only pins.
struct StartPage: View {
    /// The workspace whose pins are shown; `BrowserModel.privateSpace` for a private tab.
    let spaceID: String?
    /// The sheet's cue to grow: the content was pulled up past its top.
    let onPullUp: () -> Void
    let onOpen: (URL) -> Void
    let onOpenPin: (LocalPin) -> Void
    /// A whole page has room for frequent sites beside Zen's pins.
    let fillsPage: Bool
    /// Where a copy is drawn scrolled to; the live page reports where it comes to rest.
    let offset: CGFloat
    let onScrolled: ((CGFloat) -> Void)?
    /// A card's or transition's copy: drawn at `offset`, not scrollable.
    let isCopy: Bool
    private var isPrivate: Bool { spaceID == BrowserModel.privateSpace }
    @Environment(AccountService.self) private var account
    @Environment(BrowserModel.self) private var browser
    /// The last history read, so the next opening of the sheet draws it at once.
    private static var cache: (topSites: [HistoryStore.Entry], recent: [HistoryStore.Entry])?
    @State private var topSites = Self.cache?.topSites ?? []
    @State private var recent = Self.cache?.recent ?? []
    @State private var loaded = Self.cache != nil
    @State private var showSignIn = false
    @AppStorage(SettingsKey.signInCardHidden) private var signInCardHidden = false

    init(spaceID: String?, onPullUp: @escaping () -> Void, onOpen: @escaping (URL) -> Void,
         onOpenPin: @escaping (LocalPin) -> Void, fillsPage: Bool = false, offset: CGFloat = 0,
         onScrolled: ((CGFloat) -> Void)? = nil, isCopy: Bool = false) {
        self.spaceID = spaceID
        self.onPullUp = onPullUp
        self.onOpen = onOpen
        self.onOpenPin = onOpenPin
        self.fillsPage = fillsPage
        self.offset = offset
        self.onScrolled = onScrolled
        self.isCopy = isCopy
    }

    /// Shown until there is history or Zen pins, as Safari starts with a few popular sites.
    private static let starterSites = [
        "https://www.google.com", "https://www.youtube.com", "https://en.wikipedia.org",
        "https://github.com", "https://www.reddit.com",
    ].compactMap(URL.init(string:))

    var body: some View {
        scrolling
        .sheet(isPresented: $showSignIn) { SignInView() }
        .task(id: spaceID) {
            defer { loaded = true }
            guard !isPrivate else { return }
            (topSites, recent) = await Task.detached(priority: .userInitiated) {
                // One row per title and site: repeated searches differ only in tracking parameters.
                var seen = Set<String>()
                let recent = (HistoryStore.shared?.recent(limit: 40) ?? []).filter {
                    !$0.title.isEmpty && seen.insert("\($0.url.host() ?? "")|\($0.title)").inserted
                }
                return (HistoryStore.shared?.topSites() ?? [], Array(recent.prefix(6)))
            }.value
            Self.cache = (topSites, recent)
        }
    }


    @ViewBuilder private var scrolling: some View {
        if isCopy {
            // Shifted, not scrolled: a ScrollView dropped a position set before its first layout.
            // Laid out at full height from the top, as the ScrollView does.
            Color.clear.overlay(alignment: .top) {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: -offset)
            }
            .clipped()
        } else {
            ScrollView { content }
                .scrollIndicators(.hidden)
                // The keyboard stays while scrolling, as in Lens.
                .scrollDismissesKeyboard(.never)
                // Any pull up once past the top, not only the first: back at the low height the list stays scrolled.
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: {
                    if $1 > $0, $1 > 40 { onPullUp() }
                }
                // A new page starts at the top; its cards must not show another place.
                .onAppear { onScrolled?(0) }
                .onScrollPhaseChange { _, phase, context in
                    guard phase == .idle, let onScrolled else { return }
                    onScrolled(context.geometry.contentOffset.y + context.geometry.contentInsets.top)
                }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 28) {
            if isFirstRun { welcome }
            if loaded, !isPrivate, !account.isSignedIn, !signInCardHidden { signInCard }
            if let zen = account.zenWorkspaces {
                let space = zen.spaces.first { $0.id == spaceID }
                let essentials = zen.essentials(in: space)
                if !essentials.isEmpty {
                    section("Essentials") {
                        PinGrid(urls: essentials.map { ($0.id, $0.url) },
                                removeTitle: { _ in "Remove from Essentials" }, onOpen: onOpen)
                    }
                }
                if let space { pinned(space) }
            }
            if spaceID == nil { localPins }
            if account.zenWorkspaces == nil || fillsPage, !frequent.isEmpty {
                section("Frequently Visited") {
                    PinGrid(urls: frequent, onOpen: onOpen)
                }
            }
            if isPrivate {
                Label("Private Browsing: pages you open here aren't saved.", systemImage: "eyes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                if let device = latestDevice {
                    section("From \(NewTabView.shortName(device.clientName))") {
                        rows(
                            device.remoteTabs.sorted { $0.lastUsed > $1.lastUsed }.prefix(4).compactMap { tab in
                                tab.urlHistory.first.flatMap(URL.init(string:)).map { (tab.title, $0) }
                            }, onSelect: onOpen)
                    }
                }
                if !recent.isEmpty {
                    section("Recently Visited") {
                        rows(recent.map { ($0.title, $0.url) }, onSelect: onOpen)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 80)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// This iPhone's pins, listed as a workspace's are. Opening one goes to its tab if it is still open.
    @ViewBuilder private var localPins: some View {
        let pins = browser.localPins
        if !pins.isEmpty {
            section("Pinned") {
                rows(pins.map { ($0.title, $0.url) }, unpin: { browser.unpin(pins[$0].id) }) { url in
                    if let pin = pins.first(where: { $0.url == url }) { onOpenPin(pin) }
                }
            }
        }
    }

    /// The workspace's pinned tabs as Zen's sidebar lists them: loose ones first, then each folder.
    @ViewBuilder private func pinned(_ space: ZenWorkspaces.Space) -> some View {
        let loose = space.tabs.compactMap { tab in tab.url.map { (tab.title, $0) } }
        if !loose.isEmpty {
            let ids = space.tabs.filter { $0.url != nil }.map(\.id)
            section("Pinned") { rows(loose, unpin: { index in Task { await account.removeFromZen(ids[index]) } }, onSelect: onOpen) }
        }
        ForEach(space.folders) { folder in
            let tabs = folder.tabs.compactMap { tab in tab.url.map { (tab.title, $0) } }
            if !tabs.isEmpty {
                section(folder.name) { rows(tabs, onSelect: onOpen) }
            }
        }
    }

    /// Without Zen, the most visited sites (not in a private tab); popular ones before any history.
    private var frequent: [(id: String, url: URL?)] {
        guard !isPrivate else { return [] }
        let sites = topSites.isEmpty && loaded ? Self.starterSites : topSites.map(\.url)
        return sites.map { ($0.absoluteString, $0) }
    }

    /// Nothing of the user's yet: no history and nothing synced.
    private var isFirstRun: Bool {
        loaded && !isPrivate && recent.isEmpty && !account.isSignedIn
    }

    private var welcome: some View {
        HStack(spacing: 14) {
            SprigMark()
                .frame(width: 32, height: 32)
                .padding(12)
                .background(Palette.field, in: .rect(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to Fir").font(.brandHeading(.title2))
                Text("Search or type an address below.").foregroundStyle(.secondary)
            }
        }
    }

    /// Stays until the account is connected or the card is hidden; Settings still offers sign-in after that.
    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Bring your Zen browser along", systemImage: "arrow.triangle.2.circlepath")
                    .font(.brandHeading(.headline))
                Spacer()
                Button("Hide", systemImage: "xmark") {
                    withAnimation(.snappy) { signInCardHidden = true }
                }
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            Text(
                "Sign in with your Mozilla account to see your workspaces, pinned sites, open tabs and history from Zen."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Button("Sign In") { showSignIn = true }
                .buttonStyle(.glassProminent)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
    }

    /// The device used most recently, so the start page offers what you just left on the Mac.
    private var latestDevice: ClientRemoteTabs? {
        account.recentClients.filter { !$0.remoteTabs.isEmpty }.max {
            $0.lastModified < $1.lastModified
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.brandHeading(.title3))
            content()
        }
    }

    /// `unpin`, for pinned tabs, lets a long press unpin a row.
    private func rows(_ items: [(title: String, url: URL)], unpin: ((Int) -> Void)? = nil,
                      onSelect: @escaping (URL) -> Void) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider().padding(.leading, 56) }
                Button {
                    onSelect(item.url)
                } label: {
                    HStack(spacing: 12) {
                        SiteIcon(host: item.url.host(), size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title.isEmpty ? (item.url.host() ?? item.url.absoluteString) : item.title)
                                .lineLimit(1)
                            Text(item.url.host() ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(.rect)
                }
                .foregroundStyle(.primary)
                .contextMenu {
                    Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = item.url }
                    if let unpin {
                        Button("Unpin", systemImage: "pin.slash", role: .destructive) { unpin(index) }
                    }
                }
            }
        }
        .background(
            Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
    }
}

/// What a tab without a page shows: the sprig, with search in its sheet, or the start page itself.
/// Cards and transitions get the start page laid out at screen size and scaled, so they match the page.
struct BlankTab: View {
    let spaceID: String?
    /// The open tab, given only where it can be used; cards and transitions just show it.
    var tab: BrowserTab? = nil
    /// The page's chrome and cutouts, as the web page gets them; cards use the window's safe area.
    var insets: EdgeInsets? = nil
    /// A copy's scroll position: the tab's, so it shows the same place.
    var offset: CGFloat = 0
    @AppStorage(SettingsKey.newTabStyle) private var style = NewTabStyle.sheet
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        if style == .page {
            GeometryReader { geo in
                let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow
                let full = window?.bounds.size ?? geo.size
                let scale = min(1, geo.size.width / full.width)
                let safe = window?.safeAreaInsets ?? .zero
                StartPage(spaceID: spaceID, onPullUp: {}, onOpen: { tab?.load($0) },
                          onOpenPin: { browser.open($0, replacing: tab) }, fillsPage: true,
                          offset: offset, onScrolled: tab.map { tab in { tab.startPageOffset = $0 } },
                          isCopy: tab == nil)
                    .safeAreaPadding(insets ?? EdgeInsets(top: safe.top, leading: safe.left, bottom: 0, trailing: safe.right))
                    .frame(width: geo.size.width / scale, height: geo.size.height / scale)
                    .scaleEffect(scale, anchor: .topLeading)
                    .allowsHitTesting(tab != nil)
            }
            .ignoresSafeArea()
            // As in the search sheet: its cards are drawn for a grouped background.
            .background(Color(.systemGroupedBackground))
        } else {
            EmptyTab(swaysOnTap: tab != nil)
        }
    }
}

/// What a tab without a page shows, and its deck card: just the icon's sprig, since the search sheet has
/// the start page. Sized by width from the top, like a snapshot, so card and page match mid-transition.
struct EmptyTab: View {
    /// The open tab only: a deck card's tap opens the tab instead.
    var swaysOnTap = false
    @State private var taps = 0

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width * 0.16
            SprigMark()
                .frame(width: side, height: side)
                // A twig flicked at its tip: swings, overshoots back and settles, pivoting on the stem's base.
                .keyframeAnimator(initialValue: 0.0, trigger: taps) { sprig, angle in
                    sprig.rotationEffect(.degrees(angle), anchor: .bottomLeading)
                } keyframes: { _ in
                    SpringKeyframe(-14, duration: 0.18)
                    SpringKeyframe(9, duration: 0.28)
                    SpringKeyframe(-4, duration: 0.28)
                    SpringKeyframe(0, duration: 0.4)
                }
                .padding(24)
                .contentShape(.rect)
                .onTapGesture { taps += 1 }
                .allowsHitTesting(swaysOnTap)
                .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: taps)
                .position(x: geo.size.width / 2, y: geo.size.width * 0.95)
        }
        .background(Color(.systemGroupedBackground))
    }
}
