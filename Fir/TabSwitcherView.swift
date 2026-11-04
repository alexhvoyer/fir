import SwiftUI

/// Tab overview: an overlapping card deck (classic iOS app switcher style) of one workspace's tabs.
/// A switcher at the bottom flips between this iPhone's own tabs and each synced Zen workspace.
struct TabSwitcherView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(AccountService.self) private var account
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isLandscape) private var landscape
    /// The tab whose page is layered on top; its card stays hidden so it isn't drawn twice.
    let hiddenTab: BrowserTab.ID?
    /// Reports each card's on-screen frame so the page can grow out of it.
    let onCardFrame: (BrowserTab.ID, CGRect) -> Void
    let onOpen: () -> Void
    let onNewTab: () -> Void
    let onSettings: () -> Void
    /// A page is growing out of its card: the deck stays put, as in Safari, and centres on the
    /// selected tab only once the page covers it.
    var holdsPosition = false

    /// Fractional index of the card at the center of the screen.
    @State private var progress: CGFloat = 0
    @State private var dragOrigin: CGFloat?
    @State private var dragAxis: Axis?
    @State private var liftOffset: CGFloat = 0
    /// Another device's open tabs shown instead of a workspace; not a workspace, so not `browser.space`.
    @State private var device: String?

    private static let localSpace = "local"

    var body: some View {
        GeometryReader { geo in
            let items = switcherItems
            let selected = items.firstIndex { $0.id == selectionID } ?? 0
            // Workspaces sit side by side, as in Safari: the switcher's drag slides them under the finger.
            SpacePager(index: scrub ?? CGFloat(selected), ids: items.map(\.id), width: geo.size.width) { id in
                page(id, live: id == items[selected].id)
            }
        }
        .safeAreaInset(edge: .top) { topBar }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .background(.regularMaterial)
        // Dark like Safari's private browsing, so it's never mistaken for regular tabs.
        .environment(\.colorScheme, browser.space == BrowserModel.privateSpace ? .dark : colorScheme)
        .onAppear { centerSelected() }
        // The page sits on top of the deck; keep its card centered so it shrinks onto it.
        .onChange(of: browser.selectedID) { if !holdsPosition { centerSelected() } }
        .onChange(of: holdsPosition) { if !holdsPosition { centerSelected() } }
        // Another workspace's deck arrives already in place; a closed card's neighbours slide over.
        .onChange(of: browser.space) { centerSelected(animated: false) }
        .onChange(of: browser.spaceTabs.map(\.id)) { old, new in
            centerSelected(animated: !Set(old).isDisjoint(with: new))
        }
        // A page shrinks back onto its card, so the deck must show that tab's workspace then.
        .onChange(of: hiddenTab) {
            guard hiddenTab != nil else { return }
            device = nil
            browser.space = browser.selected.spaceID
        }
    }

    /// The fractional switcher position while workspaces slide; nil at rest.
    @State private var scrub: CGFloat?

    private var selectionID: String { device.map { Self.devicePrefix + $0 } ?? browser.space ?? Self.localSpace }

    private func select(_ id: String) {
        if id.hasPrefix(Self.devicePrefix) {
            device = String(id.dropFirst(Self.devicePrefix.count))
        } else {
            device = nil
            browser.space = id == Self.localSpace ? nil : id
            // In the same update, so the live deck takes over from its preview without a jump.
            let tabs = browser.spaceTabs
            progress = CGFloat(tabs.firstIndex { $0.id == browser.selectedID } ?? max(0, tabs.count - 1))
        }
    }

    /// A switcher entry's page. Only the selected one is live; a neighbour sliding in is drawn as it will
    /// look, with its deck centred on its newest tab, as the live one will be.
    @ViewBuilder private func page(_ id: String, live: Bool) -> some View {
        let zen = account.zenWorkspaces
        if id.hasPrefix(Self.devicePrefix) {
            if let client = account.recentClients.first(where: { Self.devicePrefix + $0.clientId == id }) {
                RemoteTabsPage(client: client, onOpen: open)
            }
        } else {
            let space: String? = id == Self.localSpace ? nil : id
            let tabs = browser.tabs(in: space)
            // Tabs of a workspace Zen no longer reports (or not loaded yet) still show, without its pins.
            let current = zen?.spaces.first { $0.id == space }
            if space == BrowserModel.privateSpace, browser.privateLocked {
                PrivateLockedPage(asks: live).environment(\.colorScheme, .dark)
            } else if space == BrowserModel.privateSpace, tabs.isEmpty {
                PrivateEmptyPage().environment(\.colorScheme, .dark)
            } else if let zen, let current, tabs.isEmpty {
                ZenSpacePage(space: current, essentials: zen.essentials(in: current), onOpen: open)
            } else {
                VStack(spacing: 0) {
                    if let zen, let current {
                        ZenSpaceHeader(space: current, essentials: zen.essentials(in: current), onOpen: open)
                    }
                    if live { deck } else { deckPreview(tabs) }
                }
            }
        }
    }

    /// Close to the screen's own shape, like Yab, so a card reads as the page shrunk. On its side the deck
    /// is short, so cards take its height instead.
    private func cardSize(in size: CGSize) -> CGSize {
        let width = landscape ? min(size.width * 0.6, size.height * 0.84 * 1.6) : size.width * 0.72
        return CGSize(width: width, height: landscape ? size.height * 0.84 : min(width * 2.05, size.height * 0.84))
    }

    private func deckPreview(_ tabs: [BrowserTab]) -> some View {
        GeometryReader { geo in
            let card = cardSize(in: geo.size)
            let step = card.width * 0.92
            // Centred where the live deck will be: on the selected tab if it's here, else the newest.
            let focus = tabs.firstIndex { $0.id == browser.selectedID } ?? tabs.count - 1
            ZStack {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    let rel = CGFloat(index - focus)
                    TabCard(tab: tab, width: card.width, height: card.height,
                            titleOpacity: max(0, 1 - Double(abs(rel)) * 2), imageHidden: false, onFrame: { _ in })
                        .equatable()
                        .scaleEffect(rel < 0 ? max(0.86, 1 + rel * 0.05) : 1)
                        .offset(x: rel < 0 ? rel * step * 0.25 : rel * step)
                        .zIndex(Double(index))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    private var deck: some View {
        GeometryReader { geo in
            let card = cardSize(in: geo.size)
            let cardWidth = card.width
            let cardHeight = card.height
            // Later cards slide in from the right over a mostly visible focused card, as in Yab.
            let step = cardWidth * 0.92
            let focused = focusedIndex

            ZStack {
                ForEach(Array(browser.spaceTabs.enumerated()), id: \.element.id) { index, tab in
                    let rel = CGFloat(index) - progress
                    // Swiping a card up to close: its title goes first so it never runs over the header,
                    // then the card shrinks a little and fades as it leaves.
                    let lift = index == focused ? min(liftOffset, 0) : 0
                    // Earlier tabs tuck in on the left. Layering follows deck order, like the app switcher:
                    // ordering by distance swapped the front card mid-scroll.
                    TabCard(tab: tab,
                            width: cardWidth, height: cardHeight,
                            titleOpacity: max(0, 1 - Double(abs(rel)) * 2) * max(0, 1 + Double(lift) / 40),
                            imageHidden: tab.id == hiddenTab,
                            onFrame: { onCardFrame(tab.id, $0) })
                        .equatable()
                        .scaleEffect((rel < 0 ? max(0.86, 1 + rel * 0.05) : 1) * (1 + lift / 1800))
                        .offset(x: rel < 0 ? rel * step * 0.25 : rel * step, y: lift)
                        .opacity(max(0, 1 + Double(lift) / 320))
                        .zIndex(Double(index))
                        .onTapGesture {
                            browser.select(tab)
                            onOpen()
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(deckGesture(step: step, height: geo.size.height))
        }
    }

    /// Opens a pinned site as a new tab of the shown workspace, growing it out of its fresh card.
    private func open(_ url: URL) {
        browser.open(url)
        onOpen()
    }

    /// Animated when the deck is on screen; instant under the page, which needs the final frame.
    private func centerSelected(animated: Bool = true) {
        withAnimation(hiddenTab == nil && animated ? .spring(response: 0.4, dampingFraction: 0.9) : nil) {
            progress = CGFloat(browser.spaceTabs.firstIndex { $0.id == browser.selectedID } ?? browser.spaceTabs.count - 1)
        }
    }

    private var focusedIndex: Int {
        min(max(Int(progress.rounded()), 0), browser.spaceTabs.count - 1)
    }

    private func deckGesture(step: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                    dragOrigin = progress
                }
                if dragAxis == .horizontal, let origin = dragOrigin {
                    progress = rubberBand(origin - value.translation.width / step)
                } else {
                    liftOffset = value.translation.height
                }
            }
            .onEnded { value in
                defer { dragAxis = nil; dragOrigin = nil }
                if dragAxis == .horizontal, let origin = dragOrigin {
                    let predicted = origin - value.predictedEndTranslation.width / step
                    let target = min(max(predicted.rounded(), 0), CGFloat(browser.spaceTabs.count - 1))
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { progress = target }
                } else if value.translation.height < -120 || value.predictedEndTranslation.height < -400 {
                    closeFocused(height: height)
                } else {
                    withAnimation(.snappy) { liftOffset = 0 }
                }
            }
    }

    /// Resists dragging past the first and last card.
    private func rubberBand(_ value: CGFloat) -> CGFloat {
        let last = CGFloat(browser.spaceTabs.count - 1)
        if value < 0 { return value / 3 }
        if value > last { return last + (value - last) / 3 }
        return value
    }

    private func closeFocused(height: CGFloat) {
        guard browser.spaceTabs.indices.contains(focusedIndex) else { return }
        let tab = browser.spaceTabs[focusedIndex]
        withAnimation(.easeIn(duration: 0.2)) {
            liftOffset = -height
        } completion: {
            // One animated update: the card leaves while still off screen (resetting its lift first
            // made it pop back), and every later card slides into the gap.
            withAnimation(.smooth(duration: 0.35)) {
                browser.close(tab)
                liftOffset = 0
                progress = max(0, min(progress.rounded(), CGFloat(browser.spaceTabs.count - 1)))
            }
        }
    }

    private var switcherItems: [SpaceSwitcher.Item] {
        let incognito = SpaceSwitcher.Item(id: BrowserModel.privateSpace, title: "Private")
        let local = SpaceSwitcher.Item(id: Self.localSpace, title: "\(browser.tabs(in: nil).count) Tabs")
        let zen = (account.zenWorkspaces?.spaces ?? []).map {
            SpaceSwitcher.Item(id: $0.id, title: [$0.icon, $0.name].compactMap { $0 }.joined(separator: " "))
        }
        // Zen's ordinary tabs sync per device with no workspace, so each device gets its own entry.
        let devices = account.recentClients.map {
            SpaceSwitcher.Item(id: Self.devicePrefix + $0.clientId, title: ($0.deviceType == .mobile ? "📱 " : "💻 ") + NewTabView.shortName($0.clientName))
        }
        return [incognito, local] + zen + devices
    }

    private static let devicePrefix = "device:"

    private var topBar: some View {
        HStack {
            Spacer()
            Button("Settings", systemImage: "gear", action: onSettings)
                .labelStyle(.iconOnly)
                .frame(width: 52, height: 52)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .font(.title3)
        .foregroundStyle(.primary)
        .padding(.horizontal, 20)
    }

    private var bottomBar: some View {
        // No GlassEffectContainer: inside one the switcher's drawn pill rendered under the glass, frosted.
        HStack(spacing: 10) {
                // With only this iPhone's tabs there is nothing to switch between.
                if switcherItems.count > 1 {
                    SpaceSwitcher(items: switcherItems,
                                  selection: Binding(get: { selectionID }, set: select), scrub: $scrub)
                } else {
                    Spacer()
                }
                Button("New Tab", systemImage: "plus", action: onNewTab)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 48, height: 48)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .foregroundStyle(.primary)
        }
        // Same size and place as the page's bar, so going to the deck reads as one bar changing.
        .padding(.horizontal, 16)
    }
}

private struct TabCard: View {
    let tab: BrowserTab
    let width: CGFloat
    let height: CGFloat
    /// Only the focused card shows its title; neighbours' labels would run under it.
    let titleOpacity: Double
    /// Under the page only the image hides: the title stays, so the shrinking page uncovers it
    /// gradually instead of it popping in once the page has landed.
    let imageHidden: Bool
    let onFrame: (CGRect) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SiteIcon(host: tab.url?.host(), size: 26, fetch: !tab.isPrivate)
                Text(tab.title).font(.headline).lineLimit(1)
                if tab.isPinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 6)
            .opacity(titleOpacity)
            Group {
                if let image = tab.snapshot {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: width, height: height, alignment: .top)
                } else if tab.url == nil {
                    StartPagePreview(spaceID: tab.spaceID)
                } else {
                    Color(.secondarySystemBackground)
                        .overlay(SiteIcon(host: tab.url?.host(), size: 56, fetch: !tab.isPrivate))
                }
            }
            .frame(width: width, height: height)
            .clipShape(.rect(cornerRadius: 34, style: .continuous))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame($0) }
            // Shadow of a plain shape behind the card: on the clipped snapshot it was redrawn every frame.
            .background {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(.black)
                    .shadow(color: .black.opacity(0.25), radius: 18, x: -6, y: 8)
            }
            .opacity(imageHidden ? 0 : 1)
        }
        .frame(width: width)
    }
}

/// The site's favicon, or a letter badge until (or unless) one loads.
struct SiteIcon: View {
    let host: String?
    let size: CGFloat
    /// Off for private tabs: fetching would write the site's icon to disk.
    var fetch = true

    var body: some View {
        Group {
            if let host, let image = Favicons.shared.icon(host).image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: size * 0.22, style: .continuous))
            } else {
                let letter = host?.replacingOccurrences(of: "www.", with: "").first.map { String($0).uppercased() } ?? "•"
                Text(letter)
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Color.secondary.opacity(0.6), in: .rect(cornerRadius: size * 0.28, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .task(id: host) {
            if let host, fetch { await Favicons.shared.load(host) }
        }
    }
}

/// A pinned site as Zen draws its essentials: a soft rounded tile with the icon in the middle.
struct PinTile: View {
    let url: URL?
    let onOpen: (URL) -> Void

    var body: some View {
        Button { url.map(onOpen) } label: {
            SiteIcon(host: url?.host(), size: 26)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(.primary.opacity(0.08), in: .rect(cornerRadius: 16, style: .continuous))
                .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

/// Pins laid out like Zen's essentials grid: up to five per row, filling the width.
struct PinGrid: View {
    let urls: [(id: String, url: URL?)]
    /// For Zen's pins and essentials: the long-press title that removes the one with this record id.
    var removeTitle: ((String) -> String?)? = nil
    /// Pinned tabs shown among essentials, marked with a pin so the two can be told apart.
    var pinnedIDs: Set<String> = []
    /// One row that scrolls sideways once there are more than four, for tight places like the deck.
    var singleRow = false
    let onOpen: (URL) -> Void
    @Environment(AccountService.self) private var account

    var body: some View {
        if singleRow, urls.count > 4 {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    // Four and a half visible, so the cut-off tile shows there's more.
                    ForEach(urls, id: \.id) { tile($0).containerRelativeFrame(.horizontal, count: 9, span: 2, spacing: 8) }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            // The header's padding stays the resting inset, but tiles scroll out to the screen's edges.
            .scrollClipDisabled()
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: max(1, min(urls.count, singleRow ? 4 : 5)))
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(urls, id: \.id) { tile($0) }
            }
        }
    }

    private func tile(_ item: (id: String, url: URL?)) -> some View {
                PinTile(url: item.url, onOpen: onOpen)
                    .overlay(alignment: .topTrailing) {
                        if pinnedIDs.contains(item.id) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(45))
                                .padding(6)
                        }
                    }
                    .contextMenu {
                        if let url = item.url {
                            Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = url }
                        }
                        if let title = removeTitle?(item.id) {
                            Button(title, systemImage: pinnedIDs.contains(item.id) ? "pin.slash" : "star.slash",
                                   role: .destructive) {
                                Task { await account.removeFromZen(item.id) }
                            }
                        }
                    }
    }
}

/// Workspace pages side by side at a fractional `index`; only the one or two in view are built. Animatable,
/// so a settling switch passes through every page in between rather than fading to the last.
private struct SpacePager<Page: View>: View, Animatable {
    var index: CGFloat
    let ids: [String]
    let width: CGFloat
    @ViewBuilder let page: (String) -> Page

    var animatableData: CGFloat {
        get { index }
        set { index = newValue }
    }

    var body: some View {
        let low = min(max(Int(index.rounded(.down)), 0), ids.count - 1)
        let high = min(max(Int(index.rounded(.up)), 0), ids.count - 1)
        ZStack {
            ForEach(Array(Set([low, high])).sorted(), id: \.self) { i in
                // Clipped at its own sides: a deck's tucked cards run past the screen's left edge and
                // covered the neighbour sliding in there. Not top and bottom, where the space's tint
                // runs on under the bars.
                page(ids[i])
                    .mask { Rectangle().padding(.vertical, -2000) }
                    .id(ids[i])
                    .offset(x: (CGFloat(i) - index) * (width + 24))
            }
        }
    }
}

/// Equal when its inputs are: the closures only touch their owner's state, so a kept copy acts the same.
/// Spares the hidden deck a re-render on every touch of a bar lift or tab swipe.
extension TabSwitcherView: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.hiddenTab == b.hiddenTab && a.holdsPosition == b.holdsPosition
    }
}

/// Equal when its inputs are; `onFrame` only forwards to the deck's owner, so a kept copy acts the same.
/// Spares every card a re-render on each frame of a workspace slide.
extension TabCard: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.tab === b.tab && a.width == b.width && a.height == b.height
            && a.titleOpacity == b.titleOpacity && a.imageHidden == b.imageHidden
    }
}
