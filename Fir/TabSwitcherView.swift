import SwiftUI

/// Tab overview: an overlapping card deck (classic iOS app switcher style) of one workspace's tabs, or
/// a grid of them.
/// A switcher at the bottom flips between this iPhone's own tabs and each synced Zen workspace.
struct TabSwitcherView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(AccountService.self) private var account
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isLandscape) private var landscape
    /// The tab whose page is layered on top; its card stays hidden so it isn't drawn twice.
    let hiddenTab: BrowserTab.ID?
    /// The later neighbour drawn over the page as it shrinks, so it isn't drawn twice either.
    var coveredTabs: Set<BrowserTab.ID> = []
    /// Reports each card's on-screen frame so the page can grow out of it.
    let onCardFrame: (BrowserTab.ID, CGRect) -> Void
    let onOpen: () -> Void
    let onNewTab: () -> Void
    let onSettings: () -> Void
    /// Settings opened on Workspaces, from a long press on the settings button.
    var onEditWorkspaces: () -> Void = {}
    /// The camera column's width when the buttons go there instead of the bars; 0 for none.
    var railWidth: CGFloat = 0
    /// Full-width pages: cards run under the column too, its buttons over them; the bottom bar stays clear.
    var underColumn = false
    /// Settings zooms out of its button and back into it, as Safari's sheets do.
    let sheetSource: Namespace.ID
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
    /// A folder picked from the folders button, for the grid to scroll to.
    @State private var folderJump: FolderJump?
    /// The deck already sits on that folder: the layout change it caused must not move it again.
    @State private var jumpedFolder = false
    /// The folder whose deletion awaits a confirmation.
    @State private var deletingFolder: DeckFolder?
    /// The card a new Zen folder is being named for.
    @State private var folderFor: BrowserTab?
    @State private var folderName = ""
    @AppStorage(SettingsKey.tabLayout) private var tabLayout = TabLayout.deck

    private static let localSpace = "local"

    var body: some View {
        GeometryReader { geo in
            let items = switcherItems
            // Never Private as the fallback: it put that page, or its Face ID, in place of the real one.
            let selected = items.firstIndex { $0.id == selectionID } ?? 1
            // Workspaces sit side by side, as in Safari: the switcher's drag slides them under the finger.
            SpacePager(index: scrub ?? CGFloat(selected), ids: items.map(\.id), width: geo.size.width,
                       bleed: carouselEdges.isEmpty ? 0 : max(geo.safeAreaInsets.leading, geo.safeAreaInsets.trailing)) { id in
                // Wider than tall (an iPhone on its side, the open Duo): the pins stand in a column.
                page(id, live: id == items[selected].id, wide: geo.size.width > geo.size.height)
            }
        }
        .safeAreaInset(edge: .top, spacing: Self.barGap) { topBar }

        .alert(deletingFolder.map { String(localized: "Delete \($0.name)?") } ?? String(localized: "Delete Folder?"), isPresented: Binding(
            get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }
        ), presenting: deletingFolder) { folder in
            Button("Delete", role: .destructive) {
                let editor = ZenFolderEditor(account: account, browser: browser)
                if let local = folder.local {
                    editor.deleteLocalFolder(local)
                } else if let space = browser.space {
                    editor.deleteZenFolder(folder, in: space)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            Text(folder.local == nil ? "Its tabs close in Zen on your computers too. Ones open here stay, outside the folder."
                 : "Its tabs close.")
        }
        .alert("New Folder", isPresented: Binding(get: { folderFor != nil }, set: { if !$0 { folderFor = nil } })) {
            TextField("Name", text: $folderName)
            Button("Create") {
                if let tab = folderFor {
                    ZenFolderEditor(account: account, browser: browser).newFolder(named: folderName, with: tab, in: zenSpace(of: tab))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ZenFolderEditor.newFolderNote(for: folderFor))
        }
        // A bar, not an inset: grid titles scrolling under it are blurred instead of read through the glass.
        .safeAreaBar(edge: .bottom) { bottomBar }
        // In the camera column, level with the bar. Not in the bar: outside its bounds the buttons took no taps.
        .overlay(alignment: .bottomTrailing) {
            if railWidth > 0 {
                VStack(spacing: 10) {
                    foldersButton
                    settingsButton
                    newTabButton
                }
                .frame(width: 52)
                .offset(x: (underColumn ? -railWidth : railWidth) / 2 + 26)
            }
        }
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
            // A new tab growing out of the front card: the deck stays put under it, as for an old one.
            // On screen too: closing another card must not spring the deck back to the selected one.
            guard !holdsPosition, hiddenTab != nil else { return }
            centerSelected(animated: !Set(old).isDisjoint(with: new))
        }
        // A card joining or leaving a folder's stack moves slots: the deck follows the card it was on.
        .onChange(of: deckLayout.slot) { old, new in
            // A folder opened from the folders button has already placed the deck on it.
            if jumpedFolder {
                jumpedFolder = false
                return
            }
            // Only when a card joined or left a stack. A reorder keeps the count, and following the old
            // slot's card then landed on the wrong one.
            // Under the page, centerSelected has already placed the deck for the new layout.
            guard hiddenTab == nil, Set(old.values).count != Set(new.values).count else { return }
            let focused = Int(progress.rounded())
            // The lowest of a stack's cards: where the stack stood.
            guard let slot = old.filter({ $0.value == focused }).compactMap({ new[$0.key] }).min() else {
                progress = min(progress, CGFloat(max(0, deckLayout.count - 1)))
                return
            }
            withAnimation(.smooth(duration: 0.35)) { progress = CGFloat(slot) }
        }
        // A workspace gone from the list (signed out, deleted) would leave an empty deck under no title.
        .onChange(of: switcherItems.map(\.id)) { _, ids in
            guard !ids.contains(selectionID) else { return }
            device = nil
            browser.space = nil
        }
        // A page shrinks back onto its card, so the deck must show that tab's workspace then.
        .onChange(of: hiddenTab) {
            guard hiddenTab != nil else { return }
            device = nil
            browser.space = browser.selected.spaceID
            // Its folder opens under the page: a grid draws only a closed folder's front tab. Not while a page
            // grows out of a side card: the deck jumped to it at the tap. It centres once the page covers it.
            if !holdsPosition { centerSelected(animated: false) }
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
    @ViewBuilder private func page(_ id: String, live: Bool, wide: Bool) -> some View {
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
            } else if let zen, let current, tabs.isEmpty, !wide {
                ZenSpacePage(space: current, essentials: zen.essentials(in: current), onOpen: open,
                             barButtonsWidth: topBarButtonsWidth)
            } else {
                // Only with pins to show: an empty column must not hold the deck's tucked cards back.
                let pinsColumn = wide && current.map { !$0.tabs.isEmpty || !(zen?.essentials(in: $0).isEmpty ?? true) } == true
                VStack(spacing: 0) {
                    if let zen, let current {
                        ZenSpaceHeader(space: current, essentials: zen.essentials(in: current), onOpen: open,
                                       barButtonsWidth: topBarButtonsWidth, pinsInRow: !wide)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        if pinsColumn, let zen, let current {
                            ZenSpacePins(space: current, essentials: zen.essentials(in: current), onOpen: open, column: true)
                                .padding(.leading, 20)
                        }
                        Group {
                            if tabs.isEmpty, let current {
                                // A workspace without tabs: its pinned tabs and folders as lists, beside the column.
                                ScrollView {
                                    ZenSpaceSections(space: current, onOpen: open)
                                        .padding(.trailing, 20)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .scrollIndicators(.hidden)
                            } else if tabLayout == .grid {
                                TabGrid(tabs: live ? browser.spaceTabs : tabs, live: live, hiddenTab: hiddenTab,
                                        holdsPosition: holdsPosition, expandedFolder: $expandedFolder,
                                        folderJump: live ? folderJump : nil,
                                        folderMenu: folderMenu, tabMenu: tabMenu, space: zenSpace(of:),
                                        onCardFrame: onCardFrame, onOpen: onOpen)
                            } else if live {
                                // Not into the side safe areas on a wide page: their reach arrived a side at a
                                // time as a switch settled, and the centred cards jumped ~40 pt and back.
                                deck(keepsLeft: pinsColumn).ignoresSafeArea(.container, edges: wide ? [] : carouselEdges)
                            } else {
                                deckPreview(tabs, keepsLeft: pinsColumn)
                                    .ignoresSafeArea(.container, edges: wide ? [] : carouselEdges)
                            }
                        }
                    }
                    // Room for an open folder's name over its card's title. Smaller beside the top bar's
                    // buttons: the header's essentials moved down there, and the cards keep their size.
                    .padding(.top, current == nil ? 0 : topBarButtonsWidth == nil ? 24 : 14)
                }
            }
        }
    }

    /// On its side, sliding cards run to the screen's edges: cut at the safe area, they left a strip. The Duo's
    /// column has its own setting.
    private var carouselEdges: Edge.Set { railWidth == 0 ? .horizontal : [] }

    /// Close to the screen's own shape, like Yab, so a card reads as the page shrunk. On its side the deck
    /// is short, so cards take its height instead.
    private func cardSize(in size: CGSize) -> CGSize {
        let width = landscape ? min(size.width * 0.6, size.height * 0.84 * 1.6) : size.width * 0.72
        return CGSize(width: width, height: landscape ? size.height * 0.84 : min(width * 2.05, size.height * 0.84))
    }

    private func deckPreview(_ tabs: [BrowserTab], keepsLeft: Bool) -> some View {
        GeometryReader { geo in
            let card = cardSize(in: geo.size)
            let step = card.width * 0.92
            let tuck = tuckLimit(keepsLeft, deck: geo.size.width, card: card.width)
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
                        .offset(x: rel < 0 ? max(rel * step * 0.25, tuck) : rel * step)
                        .zIndex(Double(slot) - Double(depth) * 0.01)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    /// How far left a tucked card may go. Beside the pins column they gather at the deck's edge: clipping
    /// the deck instead hid the folder headings' secondary-styled parts.
    private func tuckLimit(_ keepsLeft: Bool, deck width: CGFloat, card: CGFloat) -> CGFloat {
        keepsLeft ? -(width - card) / 2 : -.infinity
    }

    private func deck(keepsLeft: Bool) -> some View {
        GeometryReader { geo in
            let card = cardSize(in: geo.size)
            let cardWidth = card.width
            let cardHeight = card.height
            // Later cards slide in from the right over a mostly visible focused card, as in Yab.
            let step = cardWidth * 0.92
            let tuck = tuckLimit(keepsLeft, deck: geo.size.width, card: cardWidth)
            let layout = deckLayout
            let focused = focusedSlot
            let position = pagePosition(in: layout) ?? progress

            ZStack {
                // Over (offset, tab) pairs: ForEach straight over the tabs left the deck frozen mid-swipe.
                ForEach(Array(browser.spaceTabs.enumerated()), id: \.element.id) { _, tab in
                    let slot = layout.slot[tab.id] ?? 0
                    let depth = layout.depth[tab.id] ?? 0
                    let stack = layout.stacks[slot]
                    let rel = CGFloat(slot) - position
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
                            imageHidden: tab.id == hiddenTab || coveredTabs.contains(tab.id),
                            heading: layout.heading[tab.id] ?? .tab,
                            folderMenu: folderMenu,
                            tabMenu: tabMenu,
                            space: zenSpace(of: tab),
                            localFolders: tab.spaceID == nil ? browser.localFolders : nil,
                            onFrame: { onCardFrame(tab.id, $0) })
                        .equatable()
                        .modifier(StackDepth(depth: depth))
                        .scaleEffect((rel < 0 ? max(0.86, 1 + rel * 0.05) : 1) * (1 + lift / 1800) * (1 + pull / 600))
                        .offset(x: rel < 0 ? max(rel * step * 0.25, tuck) : rel * step, y: lift + pull)
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

    /// Under the page, the selected card's slot from the layout: the stored position lagged an update behind
    /// a sync, and the page shrank onto a stale card frame.
    private func pagePosition(in layout: DeckLayout) -> CGFloat? {
        guard hiddenTab != nil, !holdsPosition, let slot = browser.selectedID.flatMap({ layout.slot[$0] }) else { return nil }
        return CGFloat(slot)
    }

    private var focusedSlot: Int {
        min(max(Int(progress.rounded()), 0), deckLayout.count - 1)
    }

    /// Fans a folder's stack out into its cards, starting where the stack stood.
    private func expand(_ folder: DeckFolder) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { expandedFolder = folder.id }
    }

    /// The shown workspace's folders, in deck order, for the folders button.
    private var spaceFolders: [DeckFolder] {
        // Nothing from a locked Private space, not even folder names.
        guard device == nil, !(browser.space == BrowserModel.privateSpace && browser.privateLocked) else { return [] }
        var seen = Set<String>()
        return browser.spaceTabs.compactMap { browser.folder(of: $0) }
            .filter { seen.insert($0.id).inserted }
    }

    /// Opens a folder from the folders button and brings it into view: folders sit first, far from the selected tab.
    private func showFolder(_ id: String) {
        guard let tab = browser.spaceTabs.first(where: { browser.folder(of: $0)?.id == id }) else { return }
        let before = deckLayout.slot
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            expandedFolder = id
            progress = CGFloat(deckLayout.slot[tab.id] ?? 0)
        }
        jumpedFolder = before != deckLayout.slot
        folderJump = FolderJump(id: id)
    }

    private func collapse(_ folder: DeckFolder) {
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
            },
            workspaces: { account.zenWorkspaces?.spaces ?? [] },
            move: { folder, space in
                guard let local = folder.local else { return }
                ZenFolderEditor(account: account, browser: browser).moveLocalFolder(local, to: space)
            },
            ungroup: { folder in
                guard let local = folder.local else { return }
                withAnimation(.snappy) { browser.ungroup(local) }
            },
            delete: { deletingFolder = $0 }
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
                    return
                }
                let dy = value.translation.height
                let predicted = value.predictedEndTranslation.height
                // A long drag flicked back the other way is called off; a jitter before a flick isn't.
                let up = dy < -120, down = dy > 90
                if deckLayout.stacks[focusedSlot] == nil, (up && predicted < 0) || (!down && predicted < -400) {
                    closeFocused(height: height)
                } else if (down && predicted > 0) || (!up && predicted > 360) {
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
        let incognito = SpaceSwitcher.Item(id: BrowserModel.privateSpace, title: String(localized: "Private"))
        let local = SpaceSwitcher.Item(id: Self.localSpace, title: String(localized: "\(browser.tabs(in: nil).count) Tabs"))
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
        items += orphans.map { SpaceSwitcher.Item(id: $0, title: String(localized: "Other Tabs")) }
        return items
    }

    private static let devicePrefix = "device:"

    static let barHeight: CGFloat = 52
    /// Said outright, not the system default, so the workspace header can rise exactly into the bar's row.
    static let barGap: CGFloat = 8

    /// What the top bar's buttons take on the right, with a gap before the title; nil when they are elsewhere.
    private var topBarButtonsWidth: CGFloat? {
        guard railWidth == 0, !landscape else { return nil }
        return 52 + (spaceFolders.isEmpty ? 0 : 62) + 12
    }

    /// Follows the workspace's folders through withAnimation, so the button doesn't pop: the switcher picks
    /// a workspace with animations disabled, which silenced an animation modifier.
    @State private var showsFoldersButton = false

    private var topBar: some View {
        HStack(spacing: 10) {
            Spacer()
            if railWidth == 0, !landscape {
                foldersButton
                settingsButton
            }
        }
        .frame(minHeight: landscape ? 8 : Self.barHeight)
        .padding(.horizontal, 20)
        // Here, not on the body: the top bar is always on screen, and the body's chain was too long to type-check.
        .onAppear { showsFoldersButton = !spaceFolders.isEmpty }
        .onChange(of: spaceFolders.isEmpty) { _, empty in
            withAnimation(.spring(duration: 0.3)) { showsFoldersButton = !empty }
        }
    }

    private var settingsButton: some View {
        Button("Settings", systemImage: "gear", action: onSettings)
            .labelStyle(.iconOnly)
            .frame(width: 52, height: 52)
            .glassEffect(.regular.interactive(), in: .circle)
            .contextMenu {
                if account.zenWorkspaces != nil {
                    Button("Edit Workspaces…", systemImage: "square.grid.2x2", action: onEditWorkspaces)
                }
            }
            .font(.title3)
            .foregroundStyle(.primary)
            .matchedTransitionSource(id: "settings", in: sheetSource)
    }

    /// A visible button, like Safari's tab groups button: folders sit first, far from the tab the overview opens on.
    @ViewBuilder private var foldersButton: some View {
        let folders = spaceFolders
        if showsFoldersButton {
            Menu("Folders", systemImage: "folder") {
                ForEach(folders, id: \.id) { folder in
                    Button(folder.name) { showFolder(folder.id) }
                }
            }
            // Deck order: by default the menu put the first folder nearest the button, at the bottom.
            .menuOrder(.fixed)
            .labelStyle(.iconOnly)
            .frame(width: 52, height: 52)
            .glassEffect(.regular.interactive(), in: .circle)
            .font(.title3)
            .foregroundStyle(.primary)
            .accessibilityIdentifier("spaceFolders")
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }

    private var newTabButton: some View {
        Button("New Tab", systemImage: "plus", action: onNewTab)
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(width: 48, height: 48)
            .glassEffect(.regular.interactive(), in: .circle)
            .foregroundStyle(.primary)
            .accessibilityIdentifier("overviewNewTab")
    }

    private var bottomBar: some View {
        // No GlassEffectContainer: inside one the switcher's drawn pill rendered under the glass, frosted.
        HStack(spacing: 10) {
                // On its side the screen is short, and the top's edge sits under the status bar: all the
                // buttons share the bottom bar, as in Safari's tab overview.
                if landscape, railWidth == 0 {
                    settingsButton
                    foldersButton
                }
                // With only this iPhone's tabs there is nothing to switch between.
                if switcherItems.count > 1 {
                    SpaceSwitcher(items: switcherItems,
                                  selection: Binding(get: { selectionID }, set: select), scrub: $scrub)
                } else {
                    Spacer()
                }
                if railWidth == 0 { newTabButton }
        }
        // Same size and place as the page's bar, so going to the deck reads as one bar changing.
        .padding(.horizontal, 16)
        .padding(.trailing, underColumn ? railWidth : 0)
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
    /// This iPhone's folders, for one of its own tabs; nil for a workspace's or a private tab.
    var localFolders: [LocalFolder]?
    let onFrame: (CGRect) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if case .stack(let folder, let count) = heading {
                    FolderLabel(folder: folder, detail: "\(count)", font: .headline, folderMenu: folderMenu)
                } else {
                    HStack(spacing: 8) {
                        SiteIcon(host: tab.url?.host(), size: 26, fetch: !tab.isPrivate)
                        Text(tab.title).font(.headline).lineLimit(1)
                        if tab.isPinned, !tab.fromZenFolder {
                            Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                        }
                        if tabMenu != nil {
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    // The whole title opens the menu, not just the small chevron.
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                    .modifier(TitleMenu(tab: tab, space: space, local: localFolders != nil, menu: tabMenu))
                    .padding(.vertical, -6)
                    // A folder's card names its folder above the title, without moving the card.
                    .overlay(alignment: .topLeading) {
                        if case .member(let folder) = heading {
                            FolderLabel(folder: folder, detail: nil, font: .footnote, folderMenu: folderMenu).offset(y: -24)
                        }
                    }
                }
            }
            .padding(.leading, 6)
            .opacity(titleOpacity)
            CardImage(tab: tab, width: width, height: height)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame($0) }
                .accessibilityElement()
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("deckCard")
                .opacity(imageHidden ? 0 : 1)
        }
        .frame(width: width)
    }
}

/// The folder's name with a chevron that opens what can be done with it.
struct FolderLabel: View {
    let folder: DeckFolder
    let detail: String?
    let font: Font
    let folderMenu: FolderMenu?

    var body: some View {
        Menu {
            if let folderMenu {
                if folderMenu.isExpanded(folder) {
                    Button("Collapse", systemImage: "rectangle.compress.vertical") { folderMenu.collapse(folder) }
                } else {
                    Button("Expand", systemImage: "rectangle.expand.vertical") { folderMenu.expand(folder) }
                }
                if folder.local != nil {
                    let spaces = folderMenu.workspaces()
                    if !spaces.isEmpty {
                        Menu("Move to Workspace", systemImage: "arrow.up.forward.square") {
                            ForEach(spaces) { space in
                                Button([space.icon, space.name].compactMap { $0 }.joined(separator: " ")) {
                                    folderMenu.move(folder, space)
                                }
                            }
                        }
                    }
                    Button("Ungroup", systemImage: "folder.badge.minus") { folderMenu.ungroup(folder) }
                }
                if !folderMenu.openedTabs(folder).isEmpty {
                    // A Zen folder's tabs only unload; this iPhone's close for good.
                    Button(folder.local == nil ? "Unload Opened Tabs" : "Close Tabs", systemImage: "xmark") {
                        folderMenu.closeOpened(folder)
                    }
                }
                Button("Delete Folder…", systemImage: "trash", role: .destructive) { folderMenu.delete(folder) }
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
    case stack(DeckFolder, count: Int)
    case member(DeckFolder)
}

/// A card's title as the button for its menu: folders, unloading and closing.
private struct TitleMenu: ViewModifier {
    let tab: BrowserTab
    let space: ZenWorkspaces.Space?
    let local: Bool
    let menu: TabMenu?

    func body(content: Content) -> some View {
        if let menu {
            Menu {
                TabMenuItems(tab: tab, space: space, local: local, menu: menu)
            } label: {
                content
            }
            // The title keeps its own colours instead of the accent a menu's label takes.
            .buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// What can be done with a tab: pins, folders, unloading and closing. Shared by the deck and the grid.
struct TabMenuItems: View {
    let tab: BrowserTab
    let space: ZenWorkspaces.Space?
    let local: Bool
    let menu: TabMenu

    var body: some View {
        if tab.url != nil, !tab.fromZenFolder {
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab", systemImage: tab.isPinned ? "pin.slash" : "pin") {
                menu.editor.togglePin(tab)
            }
            if menu.editor.offersEssentials(tab) {
                Button(tab.zenEssentialID == nil ? "Add to Essentials" : "Remove from Essentials",
                       systemImage: tab.zenEssentialID == nil ? "star" : "star.slash") {
                    menu.editor.toggleEssential(tab)
                }
            }
        }
        if let space {
            FolderMenuItems(tab: tab, space: space, editor: menu.editor) { menu.newFolder(tab) }
            Divider()
        } else if local {
            LocalFolderMenuItems(tab: tab, browser: menu.editor.browser) { menu.newFolder(tab) }
            Divider()
        }
        if tab.fromZenFolder {
            if tab.wasOpened {
                Button("Unload Tab", systemImage: "moon.zzz") { menu.close(tab) }
            }
            // Out of Zen's folder too: the swipe only unloads, this is the way to get rid of it.
            Button("Close Tab", systemImage: "xmark", role: .destructive) { menu.editor.closeAndRemoveFromFolder(tab) }
        } else {
            Button("Close Tab", systemImage: "xmark", role: .destructive) { menu.close(tab) }
        }
    }
}

/// What a card's title menu can do: folders, and closing.
@MainActor
struct TabMenu {
    let editor: ZenFolderEditor
    let newFolder: (BrowserTab) -> Void
    let close: (BrowserTab) -> Void
}

/// What the chevron by a folder's name can do; the deck owns the state these touch.
struct FolderMenu {
    let isExpanded: (DeckFolder) -> Bool
    let expand: (DeckFolder) -> Void
    let collapse: (DeckFolder) -> Void
    let openedTabs: (DeckFolder) -> [BrowserTab]
    let closeOpened: (DeckFolder) -> Void
    /// Where a folder of this iPhone's tabs can move to.
    let workspaces: () -> [ZenWorkspaces.Space]
    let move: (DeckFolder, ZenWorkspaces.Space) -> Void
    let ungroup: (DeckFolder) -> Void
    /// Asks first; the deck shows the confirmation.
    let delete: (DeckFolder) -> Void
}

/// Where each card sits: a slot along the deck, shared by a collapsed folder's cards, which stack under
/// its first one at increasing depth.
struct DeckLayout {
    private(set) var slot: [BrowserTab.ID: Int] = [:]
    private(set) var depth: [BrowserTab.ID: Int] = [:]
    private(set) var heading: [BrowserTab.ID: CardHeading] = [:]
    /// The folder whose stack fills a slot.
    private(set) var stacks: [Int: DeckFolder] = [:]
    /// Each slot's front card.
    private(set) var first: [BrowserTab] = []
    var count: Int { first.count }

    init(_ tabs: [BrowserTab], folder: (BrowserTab) -> DeckFolder?, expanded: String?) {
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
    static let columnWidth: CGFloat = 52
    let urls: [(id: String, url: URL?)]
    /// For Zen's pins and essentials: the long-press title that removes the one with this record id.
    var removeTitle: ((String) -> String?)? = nil
    /// Pinned tabs, whose menu says Unpin; no badge, the essentials/pinned switch already tells them apart.
    var pinnedIDs: Set<String> = []
    /// One row that scrolls sideways once there are more than four, for tight places like the deck.
    var singleRow = false
    /// Stands first and scrolls away with the tiles, such as the essentials/pinned switch.
    var leading: AnyView? = nil
    /// One column that scrolls, beside the deck on a wide screen, as Zen keeps pins in its sidebar.
    var column = false
    let onOpen: (URL) -> Void
    @Environment(AccountService.self) private var account
    @State private var leadingWidth: CGFloat = 0

    var body: some View {
        if column {
            ScrollView {
                VStack(spacing: 8) {
                    leading
                    ForEach(urls, id: \.id) { tile($0) }
                }
            }
            .scrollIndicators(.hidden)
            .frame(width: Self.columnWidth)
        } else if singleRow, urls.count > 4 || leading != nil {
            // With a leading view, always this branch: switching between a long and a short list kept the
            // view, so a switch there could animate instead of being built anew.
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if let leading {
                        leading.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leadingWidth = $0 }
                    }
                    ForEach(urls, id: \.id) { tile($0).containerRelativeFrame(.horizontal) { length, _ in rowTileWidth(length) } }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollDisabled(urls.count <= 4)
            // The header's padding stays the resting inset, but tiles scroll out to the screen's edges.
            .scrollClipDisabled()
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: max(1, min(urls.count, singleRow ? 4 : 5)))
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(urls, id: \.id) { tile($0) }
            }
        }
    }

    /// Four and a half once they scroll, so the cut-off tile shows there's more; up to four share what's left.
    private func rowTileWidth(_ length: CGFloat) -> CGFloat {
        if urls.count > 4 { return (length - 8 * 8) / 9 * 2 + 8 }
        let count = CGFloat(urls.count)
        return max(0, (length - leadingWidth - 8 * count) / count)
    }

    private func tile(_ item: (id: String, url: URL?)) -> some View {
                PinTile(url: item.url, onOpen: onOpen)
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
    /// How far a page's cards may run past its sides, into the side safe areas.
    var bleed: CGFloat = 0
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
                    .mask { Rectangle().padding(.vertical, -2000).padding(.horizontal, -bleed) }
                    .id(ids[i])
                    .offset(x: (CGFloat(i) - index) * (width + 24 + 2 * bleed))
            }
        }
    }
}

/// Equal when its inputs are: the closures only touch their owner's state, so a kept copy acts the same.
/// Spares the hidden deck a re-render on every touch of a bar lift or tab swipe.
extension TabSwitcherView: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.hiddenTab == b.hiddenTab && a.coveredTabs == b.coveredTabs && a.holdsPosition == b.holdsPosition
            && a.railWidth == b.railWidth && a.underColumn == b.underColumn
    }
}

/// Equal when its inputs are; `onFrame` only forwards to the deck's owner, so a kept copy acts the same.
/// Spares every card a re-render on each frame of a workspace slide.
extension TabCard: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.tab === b.tab && a.width == b.width && a.height == b.height
            && a.titleOpacity == b.titleOpacity && a.imageHidden == b.imageHidden && a.heading == b.heading
            && (a.folderMenu == nil) == (b.folderMenu == nil) && (a.tabMenu == nil) == (b.tabMenu == nil)
            && a.space?.id == b.space?.id && a.space?.folders == b.space?.folders && a.localFolders == b.localFolders
    }
}

/// A card's picture of its page, with its corners and shadow; also drawn over a shrinking page.
struct CardImage: View {
    let tab: BrowserTab
    let width: CGFloat
    let height: CGFloat
    var radius: CGFloat = 34

    var body: some View {
        Group {
            if let image = tab.snapshot {
                // Cropped from the top left, as the page reads: centred, a wide page lost its left edge.
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: width, height: height, alignment: .topLeading)
            } else if tab.url == nil {
                BlankTab(spaceID: tab.spaceID, offset: tab.startPageOffset)
                    // A new offset alone didn't redraw the card's copy.
                    .id(tab.startPageOffset)
            } else {
                Color(.secondarySystemBackground)
                    .overlay(SiteIcon(host: tab.url?.host(), size: 56, fetch: !tab.isPrivate))
            }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
        // Shadow of a plain shape behind the card: on the clipped snapshot it was redrawn every frame.
        .background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.black)
                .shadow(color: .black.opacity(0.25), radius: 18, x: -6, y: 8)
        }
    }
}
