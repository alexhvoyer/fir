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
    /// Counts tabs opened by pulling their card down; each one taps, a plain tap on the card doesn't.
    @State private var pullOpens = 0
    /// Another device's open tabs shown instead of a workspace; not a workspace, so not `browser.space`.
    @State private var device: String?
    /// The Zen folder laid out as separate cards; every other folder is a stack. The selected tab's opens.
    @State private var expandedFolder: String?
    /// The card a new Zen folder is being named for.
    @State private var folderFor: BrowserTab?
    @State private var folderName = ""

    private static let localSpace = "local"

    var body: some View {
        GeometryReader { geo in
            let items = switcherItems
            // Never Private as the fallback: it put that page, or its Face ID, in place of the real one.
            let selected = items.firstIndex { $0.id == selectionID } ?? 1
            // Workspaces sit side by side, as in Safari: the switcher's drag slides them under the finger.
            SpacePager(index: scrub ?? CGFloat(selected), ids: items.map(\.id), width: geo.size.width) { id in
                page(id, live: id == items[selected].id)
            }
        }
        .safeAreaInset(edge: .top) { topBar }
        .alert("New Folder", isPresented: Binding(get: { folderFor != nil }, set: { if !$0 { folderFor = nil } })) {
            TextField("Name", text: $folderName)
            Button("Create") {
                if let tab = folderFor, let space = zenSpace(of: tab) {
                    ZenFolderEditor(account: account, browser: browser).createFolder(named: folderName, with: tab, in: space)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The folder appears in Zen too, with this page in it.")
        }
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
        // A card joining or leaving a folder's stack moves slots: the deck follows the card it was on.
        .onChange(of: deckLayout.slot) { old, new in
            let focused = Int(progress.rounded())
            guard let id = old.first(where: { $0.value == focused })?.key, let slot = new[id] else {
                progress = min(progress, CGFloat(max(0, deckLayout.count - 1)))
                return
            }
            withAnimation(.smooth(duration: 0.35)) { progress = CGFloat(slot) }
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
            let layout = deckLayout
            progress = CGFloat(browser.selectedID.flatMap { layout.slot[$0] } ?? max(0, layout.count - 1))
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
                    Group {
                        if live { deck } else { deckPreview(tabs) }
                    }
                    // Room for an open folder's name over its card's title.
                    .padding(.top, current == nil ? 0 : 24)
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
            let layout = DeckLayout(tabs, folder: browser.folder, expanded: nil)
            let focus = tabs.first { $0.id == browser.selectedID }.map { layout.slot[$0.id] ?? 0 } ?? layout.count - 1
            ZStack {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { _, tab in
                    let slot = layout.slot[tab.id] ?? 0
                    let depth = layout.depth[tab.id] ?? 0
                    let rel = CGFloat(slot - focus)
                    TabCard(tab: tab, width: card.width, height: card.height,
                            titleOpacity: depth > 0 ? 0 : max(0, 1 - Double(abs(rel)) * 2), imageHidden: false,
                            heading: layout.heading[tab.id] ?? .tab, onFrame: { _ in })
                        .equatable()
                        .modifier(StackDepth(depth: depth))
                        .scaleEffect(rel < 0 ? max(0.86, 1 + rel * 0.05) : 1)
                        .offset(x: rel < 0 ? rel * step * 0.25 : rel * step)
                        .zIndex(Double(slot) - Double(depth) * 0.01)
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
            let layout = deckLayout
            let focused = focusedSlot

            ZStack {
                // Over (offset, tab) pairs: ForEach straight over the tabs left the deck frozen mid-swipe.
                ForEach(Array(browser.spaceTabs.enumerated()), id: \.element.id) { _, tab in
                    let slot = layout.slot[tab.id] ?? 0
                    let depth = layout.depth[tab.id] ?? 0
                    let stack = layout.stacks[slot]
                    let rel = CGFloat(slot) - progress
                    // Swiping a card up to close: its title goes first so it never runs over the header,
                    // then the card shrinks a little and fades as it leaves. A folder's stack doesn't close.
                    let lift = slot == focused && stack == nil ? min(liftOffset, 0) : 0
                    // Pulled down it follows at a third of the finger and grows a touch, toward the page.
                    let pull = slot == focused ? max(liftOffset, 0) / 3 : 0
                    // Earlier tabs tuck in on the left. Layering follows deck order, like the app switcher:
                    // ordering by distance swapped the front card mid-scroll.
                    TabCard(tab: tab,
                            width: cardWidth, height: cardHeight,
                            titleOpacity: depth > 0 ? 0 : max(0, 1 - Double(abs(rel)) * 2) * max(0, 1 + Double(lift) / 40),
                            imageHidden: tab.id == hiddenTab,
                            heading: layout.heading[tab.id] ?? .tab,
                            folderMenu: folderMenu,
                            tabMenu: tabMenu,
                            space: zenSpace(of: tab),
                            onFrame: { onCardFrame(tab.id, $0) })
                        .equatable()
                        .modifier(StackDepth(depth: depth))
                        .scaleEffect((rel < 0 ? max(0.86, 1 + rel * 0.05) : 1) * (1 + lift / 1800) * (1 + pull / 600))
                        .offset(x: rel < 0 ? rel * step * 0.25 : rel * step, y: lift + pull)
                        .opacity(max(0, 1 + Double(lift) / 320))
                        .zIndex(Double(slot) - Double(depth) * 0.01)
                        .onTapGesture {
                            if let stack { expand(stack) } else { browser.select(tab); onOpen() }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(deckGesture(step: step, height: geo.size.height))
            .haptic(.impact(weight: .light), trigger: pullOpens)
        }
    }

    /// Opens a pinned site as a new tab of the shown workspace, growing it out of its fresh card.
    private func open(_ url: URL) {
        browser.open(url)
        onOpen()
    }

    /// Animated when the deck is on screen; instant under the page, which needs the final frame. The
    /// selected tab's folder lays out its cards, so the page has its own card to shrink onto.
    private func centerSelected(animated: Bool = true) {
        if let folder = browser.folder(of: browser.selected), browser.selected.spaceID == browser.space {
            expandedFolder = folder.id
        }
        let layout = deckLayout
        withAnimation(hiddenTab == nil && animated ? .spring(response: 0.4, dampingFraction: 0.9) : nil) {
            progress = CGFloat(browser.selectedID.flatMap { layout.slot[$0] } ?? max(0, layout.count - 1))
        }
    }

    private var deckLayout: DeckLayout {
        DeckLayout(browser.spaceTabs, folder: browser.folder, expanded: expandedFolder)
    }

    private var focusedSlot: Int {
        min(max(Int(progress.rounded()), 0), deckLayout.count - 1)
    }

    /// Fans a folder's stack out into its cards, starting where the stack stood.
    private func expand(_ folder: ZenWorkspaces.Folder) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { expandedFolder = folder.id }
    }

    private func collapse(_ folder: ZenWorkspaces.Folder) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            expandedFolder = nil
            let layout = deckLayout
            if let first = browser.spaceTabs.first(where: { browser.folder(of: $0)?.id == folder.id }) {
                progress = CGFloat(layout.slot[first.id] ?? 0)
            } else {
                progress = min(progress, CGFloat(layout.count - 1))
            }
        }
    }

    private func zenSpace(of tab: BrowserTab) -> ZenWorkspaces.Space? {
        guard !tab.isPrivate else { return nil }
        return account.zenWorkspaces?.spaces.first { $0.id == tab.spaceID }
    }

    private var tabMenu: TabMenu {
        TabMenu(
            editor: ZenFolderEditor(account: account, browser: browser),
            newFolder: { tab in
                folderName = ""
                folderFor = tab
            },
            close: { tab in
                withAnimation(.smooth(duration: 0.35)) {
                    browser.close(tab, inPlace: true)
                    progress = max(0, min(progress.rounded(), CGFloat(deckLayout.count - 1)))
                }
            }
        )
    }

    private var folderMenu: FolderMenu {
        FolderMenu(
            isExpanded: { $0.id == expandedFolder },
            expand: expand,
            collapse: collapse,
            openedTabs: { folder in browser.spaceTabs.filter { browser.folder(of: $0)?.id == folder.id && $0.wasOpened } },
            closeOpened: { folder in
                withAnimation(.smooth(duration: 0.35)) {
                    for tab in browser.spaceTabs where browser.folder(of: tab)?.id == folder.id && tab.wasOpened {
                        browser.close(tab, inPlace: true)
                    }
                }
            }
        )
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
                    let target = min(max(predicted.rounded(), 0), CGFloat(deckLayout.count - 1))
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { progress = target }
                } else if deckLayout.stacks[focusedSlot] == nil,
                          value.translation.height < -120 || value.predictedEndTranslation.height < -400 {
                    closeFocused(height: height)
                } else if value.translation.height > 90 || value.predictedEndTranslation.height > 360 {
                    openFocused()
                } else {
                    withAnimation(.snappy) { liftOffset = 0 }
                }
            }
    }

    /// Resists dragging past the first and last card.
    private func rubberBand(_ value: CGFloat) -> CGFloat {
        let last = CGFloat(deckLayout.count - 1)
        if value < 0 { return value / 3 }
        if value > last { return last + (value - last) / 3 }
        return value
    }

    /// Pulling a card down opens it, as swiping one up closes it; it grows from where the pull left it.
    private func openFocused() {
        let layout = deckLayout
        guard layout.first.indices.contains(focusedSlot) else { return }
        pullOpens += 1
        if let stack = layout.stacks[focusedSlot] {
            expand(stack)
            withAnimation(.snappy) { liftOffset = 0 }
            return
        }
        browser.select(layout.first[focusedSlot])
        onOpen()
        // Dropped back once the page covers the deck: at once, the page grew from the card's old place.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(nil) { liftOffset = 0 }
        }
    }

    private func closeFocused(height: CGFloat) {
        let layout = deckLayout
        guard layout.first.indices.contains(focusedSlot) else { return }
        let tab = layout.first[focusedSlot]
        withAnimation(.easeIn(duration: 0.2)) {
            liftOffset = -height
        } completion: {
            // One animated update: the card leaves while still off screen (resetting its lift first
            // made it pop back), and every later card slides into the gap.
            withAnimation(.smooth(duration: 0.35)) {
                browser.close(tab, inPlace: true)
                liftOffset = 0
                progress = max(0, min(progress.rounded(), CGFloat(deckLayout.count - 1)))
            }
        }
    }

    private var switcherItems: [SpaceSwitcher.Item] {
        let incognito = SpaceSwitcher.Item(id: BrowserModel.privateSpace, title: "Private")
        let local = SpaceSwitcher.Item(id: Self.localSpace, title: browser.tabs(in: nil).count == 1 ? "1 Tab" : "\(browser.tabs(in: nil).count) Tabs")
        let zen = (account.zenWorkspaces?.spaces ?? []).map {
            SpaceSwitcher.Item(id: $0.id, title: [$0.icon, $0.name].compactMap { $0 }.joined(separator: " "))
        }
        // Zen's ordinary tabs sync per device with no workspace, so each device gets its own entry.
        let devices = account.recentClients.map {
            SpaceSwitcher.Item(id: Self.devicePrefix + $0.clientId, title: ($0.deviceType == .mobile ? "📱 " : "💻 ") + NewTabView.shortName($0.clientName))
        }
        var items = [incognito, local] + zen + devices
        // A workspace Zen no longer lists (sync off, signed out, deleted there) keeps its tabs reachable.
        let orphans = Set(browser.tabs.compactMap(\.spaceID)).subtracting(items.map(\.id)).sorted()
        items += orphans.map { SpaceSwitcher.Item(id: $0, title: "Other Tabs") }
        return items
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
    var heading: CardHeading = .tab
    var folderMenu: FolderMenu?
    /// The chevron by a live card's title; off in previews.
    var tabMenu: TabMenu?
    /// The Zen workspace the tab is in, for its folders; nil for this iPhone's tabs and private ones.
    var space: ZenWorkspaces.Space?
    let onFrame: (CGRect) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if case .stack(let folder, let count) = heading {
                    folderLabel(folder, detail: "\(count)", font: .headline)
                } else {
                    HStack(spacing: 8) {
                        SiteIcon(host: tab.url?.host(), size: 26, fetch: !tab.isPrivate)
                        Text(tab.title).font(.headline).lineLimit(1)
                        if tab.isPinned, !tab.fromZenFolder {
                            Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                        }
                        if let tabMenu {
                            Menu {
                                if let space {
                                    FolderMenuItems(tab: tab, space: space, editor: tabMenu.editor) { tabMenu.newFolder(tab) }
                                    Divider()
                                }
                                Button("Close Tab", systemImage: "xmark", role: .destructive) { tabMenu.close(tab) }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, height: 28)
                                    .contentShape(.rect)
                            }
                            // Grey like the folder's chevron, not the accent a menu's label takes.
                            .tint(.secondary)
                        }
                    }
                    // A folder's card names its folder above the title, without moving the card.
                    .overlay(alignment: .topLeading) {
                        if case .member(let folder) = heading {
                            folderLabel(folder, detail: nil, font: .footnote).offset(y: -24)
                        }
                    }
                }
            }
            .padding(.leading, 6)
            .opacity(titleOpacity)
            Group {
                if let image = tab.snapshot {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: width, height: height, alignment: .top)
                } else if tab.url == nil {
                    EmptyTab()
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

    /// The folder's name with a chevron that opens what can be done with it.
    private func folderLabel(_ folder: ZenWorkspaces.Folder, detail: String?, font: Font) -> some View {
        Menu {
            if let folderMenu {
                if folderMenu.isExpanded(folder) {
                    Button("Collapse", systemImage: "rectangle.compress.vertical") { folderMenu.collapse(folder) }
                } else {
                    Button("Expand", systemImage: "rectangle.expand.vertical") { folderMenu.expand(folder) }
                }
                if !folderMenu.openedTabs(folder).isEmpty {
                    Button("Close Opened Tabs", systemImage: "xmark", role: .destructive) { folderMenu.closeOpened(folder) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(folder.name).lineLimit(1)
                if let detail { Text(detail).foregroundStyle(.secondary) }
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .font(font)
            .contentShape(.rect)
        }
        .foregroundStyle(.primary)
        .disabled(folderMenu == nil)
    }
}

/// What a card's title row shows: its page, a folder's whole stack, or a page that belongs to a folder.
enum CardHeading: Equatable {
    case tab
    case stack(ZenWorkspaces.Folder, count: Int)
    case member(ZenWorkspaces.Folder)
}

/// What the chevron by a card's title can do: folders, and closing.
@MainActor
struct TabMenu {
    let editor: ZenFolderEditor
    let newFolder: (BrowserTab) -> Void
    let close: (BrowserTab) -> Void
}

/// What the chevron by a folder's name can do; the deck owns the state these touch.
struct FolderMenu {
    let isExpanded: (ZenWorkspaces.Folder) -> Bool
    let expand: (ZenWorkspaces.Folder) -> Void
    let collapse: (ZenWorkspaces.Folder) -> Void
    let openedTabs: (ZenWorkspaces.Folder) -> [BrowserTab]
    let closeOpened: (ZenWorkspaces.Folder) -> Void
}

/// Where each card sits: a slot along the deck, shared by a collapsed folder's cards, which stack under
/// its first one at increasing depth.
struct DeckLayout {
    private(set) var slot: [BrowserTab.ID: Int] = [:]
    private(set) var depth: [BrowserTab.ID: Int] = [:]
    private(set) var heading: [BrowserTab.ID: CardHeading] = [:]
    /// The folder whose stack fills a slot.
    private(set) var stacks: [Int: ZenWorkspaces.Folder] = [:]
    /// Each slot's front card.
    private(set) var first: [BrowserTab] = []
    var count: Int { first.count }

    init(_ tabs: [BrowserTab], folder: (BrowserTab) -> ZenWorkspaces.Folder?, expanded: String?) {
        var stackSlot: [String: Int] = [:]
        let sizes = Dictionary(tabs.compactMap { folder($0)?.id }.map { ($0, 1) }, uniquingKeysWith: +)
        for tab in tabs {
            guard let owner = folder(tab) else {
                slot[tab.id] = first.count
                first.append(tab)
                continue
            }
            if owner.id == expanded {
                slot[tab.id] = first.count
                heading[tab.id] = .member(owner)
                first.append(tab)
            } else if let shared = stackSlot[owner.id] {
                slot[tab.id] = shared
                depth[tab.id] = tabs.filter { slot[$0.id] == shared }.count - 1
            } else {
                stackSlot[owner.id] = first.count
                slot[tab.id] = first.count
                stacks[first.count] = owner
                heading[tab.id] = .stack(owner, count: sizes[owner.id] ?? 1)
                first.append(tab)
            }
        }
    }
}

/// A card deeper in a folder's stack: nudged left and down a size, so the edges show like a fanned pile.
private struct StackDepth: ViewModifier {
    let depth: Int

    func body(content: Content) -> some View {
        let shown = CGFloat(min(depth, 3))
        content
            .scaleEffect(1 - shown * 0.04)
            .offset(x: -shown * 20)
            .brightness(-shown * 0.04)
            .opacity(depth > 3 ? 0 : 1)
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
            && a.titleOpacity == b.titleOpacity && a.imageHidden == b.imageHidden && a.heading == b.heading
            && (a.folderMenu == nil) == (b.folderMenu == nil) && (a.tabMenu == nil) == (b.tabMenu == nil)
            && a.space?.id == b.space?.id && a.space?.folders == b.space?.folders
    }
}
