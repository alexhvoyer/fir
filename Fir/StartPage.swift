import MozillaAppServices
import SwiftUI

/// What an empty tab shows, like Safari's start page: the workspace's Zen essentials and pinned tabs,
/// the newest tabs from Zen and recent history. Also the search screen before anything is typed. A
/// private tab shows only pins, so its start page reveals no history.
struct StartPage: View {
    /// The workspace whose Zen pins are shown; `BrowserModel.privateSpace` for a private tab.
    let spaceID: String?
    let insets: EdgeInsets
    /// Clear on the search sheet, whose glass shows through.
    var background = Color(.systemGroupedBackground)
    /// The search sheet's cue to grow: the content was pulled up past its top.
    var onPullUp: (() -> Void)? = nil
    let onOpen: (URL) -> Void
    private var isPrivate: Bool { spaceID == BrowserModel.privateSpace }
    @Environment(AccountService.self) private var account
    /// The last history read, so another copy of the page (a deck card, a transition) draws it at once.
    private static var cache: (topSites: [HistoryStore.Entry], recent: [HistoryStore.Entry])?
    @State private var topSites = Self.cache?.topSites ?? []
    @State private var recent = Self.cache?.recent ?? []
    @State private var loaded = Self.cache != nil
    @State private var showSignIn = false
    @AppStorage(SettingsKey.signInCardHidden) private var signInCardHidden = false

    /// Shown until there is history or Zen pins, as Safari starts with a few popular sites.
    private static let starterSites = [
        "https://www.google.com", "https://www.youtube.com", "https://en.wikipedia.org",
        "https://github.com", "https://www.reddit.com",
    ].compactMap(URL.init(string:))

    var body: some View {
        ScrollView {
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
                if account.zenWorkspaces == nil, !frequent.isEmpty {
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
            .padding(.bottom, insets.bottom + 80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The status bar's inset as the scroll view's, not the content's: the refresh spinner sits at
        // the top of that inset, which had put it behind the Dynamic Island.
        .safeAreaPadding(.top, insets.top)
        .scrollIndicators(.hidden)
        // Pull down for Zen's latest pins and essentials; not on the search sheet, where it closes the sheet.
        .refreshable(isEnabled: onPullUp == nil && account.isSignedIn) { await account.sync() }
        // On the search sheet the keyboard stays while scrolling, as in Lens.
        .scrollDismissesKeyboard(.never)
        // Any pull up once past the top, not only the first: back at the low height the list stays scrolled.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: {
            if $1 > $0, $1 > 40 { onPullUp?() }
        }
        .background(background)
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

    /// The workspace's pinned tabs as Zen's sidebar lists them: loose ones first, then each folder.
    @ViewBuilder private func pinned(_ space: ZenWorkspaces.Space) -> some View {
        let loose = space.tabs.compactMap { tab in tab.url.map { (tab.title, $0) } }
        if !loose.isEmpty {
            section("Pinned") { rows(loose, ids: space.tabs.filter { $0.url != nil }.map(\.id), onSelect: onOpen) }
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

    /// `ids`, for Zen's pinned tabs, lets a long press unpin a row in Zen.
    private func rows(_ items: [(title: String, url: URL)], ids: [String]? = nil,
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
                    if let id = ids?[index] {
                        Button("Unpin", systemImage: "pin.slash", role: .destructive) {
                            Task { await account.removeFromZen(id) }
                        }
                    }
                }
            }
        }
        .background(
            Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
    }
}

private extension View {
    @ViewBuilder func refreshable(isEnabled: Bool, action: @escaping @Sendable () async -> Void) -> some View {
        if isEnabled { refreshable(action: action) } else { self }
    }
}

/// The start page drawn at full-screen size and scaled to fit, top-aligned: what a deck card and the
/// deck transitions show for a tab without a page, which has no snapshot.
struct StartPagePreview: View {
    let spaceID: String?

    var body: some View {
        GeometryReader { geo in
            let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow
            let screen = window?.bounds.size ?? geo.size
            let scale = geo.size.width / max(screen.width, 1)
            StartPage(spaceID: spaceID,
                      insets: EdgeInsets(top: window?.safeAreaInsets.top ?? 0, leading: 0,
                                         bottom: window?.safeAreaInsets.bottom ?? 0, trailing: 0),
                      onOpen: { _ in })
                .frame(width: screen.width, height: geo.size.height / max(scale, 0.01))
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}
