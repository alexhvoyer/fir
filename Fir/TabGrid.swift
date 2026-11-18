import SwiftUI
import UIKit.UIGestureRecognizerSubclass

/// The tab overview as a grid, as in Safari: a workspace's tabs side by side. A closed folder is one
/// cell; an open one gets its own row under its name.
struct TabGrid: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.isLandscape) private var landscape
    @Environment(\.isWideScreen) private var wide
    let tabs: [BrowserTab]
    /// Off for a workspace sliding in beside the shown one: drawn, never touched or measured.
    let live: Bool
    /// The tab whose page is on top; its picture stays hidden so it isn't drawn twice.
    let hiddenTab: BrowserTab.ID?
    /// A page is growing out of its cell: the grid doesn't scroll under it.
    let holdsPosition: Bool
    @Binding var expandedFolder: String?
    let folderMenu: FolderMenu?
    let tabMenu: TabMenu?
    let space: (BrowserTab) -> ZenWorkspaces.Space?
    let onCardFrame: (BrowserTab.ID, CGRect) -> Void
    let onOpen: () -> Void

    /// Tabs whose cells are flying off to the left; each closes once its cell is off screen.
    @State private var closing: Set<BrowserTab.ID> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Smaller than the deck's: a cell is under half the screen wide. The page's mask lands on it.
    static let radius: CGFloat = 22
    private static let spacing: CGFloat = 14
    private static let margin: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            // Wide but not on its side: the Duo's open screen, where Safari shows three page-shaped cells.
            // Screen shape, not grid area: bars made a near-square grid read wide.
            let minWidth: CGFloat = wide && !landscape ? 260 : 160
            let columns = max(2, Int((geo.size.width - 2 * Self.margin + Self.spacing) / (minWidth + Self.spacing)))
            let width = (geo.size.width - 2 * Self.margin - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns)
            // Upright, a cell keeps the top of the page; on a wide screen the cell is wide too.
            let height = width * (wide ? 0.7 : 1.38)
            ScrollViewReader { proxy in
                ScrollView {
                    // Not LazyVGrid: its cells kept a page's picture hidden after the page closed, though the
                    // grid itself had updated. The deck draws every card too.
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(sections) { section in
                            if let folder = section.folder {
                                FolderLabel(folder: folder, detail: nil, font: .headline, folderMenu: live ? folderMenu : nil)
                                    .padding(.top, 8)
                            }
                            // One layout per section, not a stack per row: a cell moving up a row stays the
                            // same view, so it slides there instead of popping in.
                            GridRows(columns: columns, spacing: Self.spacing, rowSpacing: 22) {
                                ForEach(section.cells) { cell($0, width: width, height: height, screen: geo.size.width) }
                            }
                        }
                    }
                    .padding(.horizontal, Self.margin)
                    // Room above for a closed folder's pile.
                    .padding(.vertical, 20)
                }
                .scrollDisabled(!live)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .onAppear { reveal(in: proxy) }
                // Under the page the grid keeps the selected cell in view, so the page has a cell to land on.
                .onChange(of: browser.selectedID) { if !holdsPosition { reveal(in: proxy) } }
                .onChange(of: holdsPosition) { if !holdsPosition { reveal(in: proxy) } }
                // Not while a page grows out of its cell: the grid jumped under it. It centres once the page covers it.
                .onChange(of: hiddenTab) { if hiddenTab != nil, !holdsPosition { reveal(in: proxy) } }
                .onChange(of: expandedFolder) { if hiddenTab != nil { reveal(in: proxy) } }
            }
        }
        .allowsHitTesting(live)
    }

    /// Centres the selected tab's cell. On the next update: its folder may only now be opening.
    private func reveal(in proxy: ScrollViewProxy) {
        guard live, let id = browser.selectedID, tabs.contains(where: { $0.id == id }) else { return }
        Task {
            await Task.yield()
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private struct GridSection: Identifiable {
        let id: String
        /// Named only for an open folder; the other sections are plain runs of cells.
        let folder: DeckFolder?
        var cells: [Cell]
    }

    private enum Cell: Identifiable {
        case tab(BrowserTab)
        /// A closed folder: its first tab's picture with the rest piled behind.
        case stack(DeckFolder, front: BrowserTab, count: Int)

        var id: BrowserTab.ID {
            switch self {
            case .tab(let tab), .stack(_, let tab, _): tab.id
            }
        }
    }

    private var sections: [GridSection] {
        let layout = DeckLayout(tabs, folder: browser.folder, expanded: expandedFolder)
        var sections: [GridSection] = []
        for (slot, front) in layout.first.enumerated() {
            let cell: Cell
            var folder: DeckFolder?
            if let stack = layout.stacks[slot], case .stack(_, let count) = layout.heading[front.id] {
                cell = .stack(stack, front: front, count: count)
            } else {
                cell = .tab(front)
                if case .member(let owner) = layout.heading[front.id] { folder = owner }
            }
            if let last = sections.last, last.folder?.id == folder?.id {
                sections[sections.count - 1].cells.append(cell)
            } else {
                sections.append(GridSection(id: folder?.id ?? "run-\(front.id)", folder: folder, cells: [cell]))
            }
        }
        return sections
    }

    @ViewBuilder private func cell(_ cell: Cell, width: CGFloat, height: CGFloat, screen: CGFloat) -> some View {
        switch cell {
        case .tab(let tab):
            tabCell(tab, width: width, height: height, screen: screen)
        case .stack(let folder, let front, let count):
            VStack(spacing: 8) {
                picture(front, width: width, height: height)
                    .background {
                        // The pile behind: two edges peeking out above, as the deck fans its stacks.
                        ForEach(1..<min(count, 3), id: \.self) { depth in
                            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                                .fill(Color(.systemGray3).opacity(1 - Double(depth) * 0.35))
                                .scaleEffect(x: 1 - CGFloat(depth) * 0.08, y: 1)
                                .offset(y: -CGFloat(depth) * 8)
                        }
                    }
                FolderLabel(folder: folder, detail: "\(count)", font: .footnote, folderMenu: live ? folderMenu : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: width)
            .contentShape(.rect)
            .onTapGesture { withAnimation(.snappy) { expandedFolder = folder.id } }
            .id(front.id)
        }
    }

    private func tabCell(_ tab: BrowserTab, width: CGFloat, height: CGFloat, screen: CGFloat) -> some View {
        GridCell(tab: tab, width: width, height: height, hidden: tab.id == hiddenTab,
                 selected: tab.id == browser.selectedID, live: live, tabMenu: tabMenu, space: space(tab),
                 leaving: closing.contains(tab.id), flight: screen,
                 onFrame: { onCardFrame(tab.id, $0) }, onClose: { close(tab) }) {
            browser.select(tab)
            onOpen()
        }
        .id(tab.id)
    }

    /// The cell flies off, then the tab closes on a timer: the animation's completion didn't always come.
    /// Unmarked, a cell still here (Undo, a Zen unload) slides back.
    private func close(_ tab: BrowserTab) {
        guard let tabMenu, !closing.contains(tab.id) else { return }
        guard !reduceMotion else { return tabMenu.close(tab) }
        closing.insert(tab.id)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(GridCell.flightTime))
            // The tab as it is now: a sync or an unload may have replaced it under this id, or removed it.
            if let current = browser.tabs.first(where: { $0.id == tab.id }) { tabMenu.close(current) }
            // Not before the removal has played out: a view still leaving watches the mark and would turn back.
            try? await Task.sleep(for: .seconds(0.5))
            closing.remove(tab.id)
        }
    }

    private func picture(_ tab: BrowserTab, width: CGFloat, height: CGFloat) -> some View {
        GridPicture(tab: tab, width: width, height: height, hidden: tab.id == hiddenTab, live: live) {
            onCardFrame(tab.id, $0)
        }
    }
}

/// A tab's picture in the grid, measured so the page can grow out of it.
private struct GridPicture: View {
    let tab: BrowserTab
    let width: CGFloat
    let height: CGFloat
    /// Under its own page: not drawn twice.
    let hidden: Bool
    let live: Bool
    let onFrame: (CGRect) -> Void

    var body: some View {
        ZStack {
            if !hidden { CardImage(tab: tab, width: width, height: height, radius: TabGrid.radius) }
        }
        .frame(width: width, height: height)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            if live { onFrame(frame) }
        }
    }
}

/// One tab in the grid: its picture with a close button, and its title under it. Swiped left, as in
/// Safari, it follows the finger and closes past a third of its width.
private struct GridCell: View {
    let tab: BrowserTab
    let width: CGFloat
    let height: CGFloat
    let hidden: Bool
    let selected: Bool
    let live: Bool
    let tabMenu: TabMenu?
    let space: ZenWorkspaces.Space?
    /// Its tab is closing: the cell flies this far left, and slides back if it is still here after.
    let leaving: Bool
    let flight: CGFloat
    let onFrame: (CGRect) -> Void
    let onClose: () -> Void
    let onSelect: () -> Void
    @State private var dragX: CGFloat = 0
    /// Over its neighbours from the first move until it has slid back, not only while the finger is down.
    @State private var lifted = false
    /// A finger is on it: it rises a little, as Safari's cells do.
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let flightTime = 0.3

    /// A Zen folder's tab only unloads, so one never opened has nothing to swipe away.
    private var swipes: Bool { tabMenu != nil && !hidden && !leaving && (!tab.fromZenFolder || tab.wasOpened) }

    var body: some View {
        VStack(spacing: 8) {
            // The press lift scales the cell; the page grows from, and shrinks onto, its resting frame.
            GridPicture(tab: tab, width: width, height: height, hidden: hidden, live: live) { if !pressed { onFrame($0) } }
                .overlay {
                    if selected, !hidden {
                        RoundedRectangle(cornerRadius: TabGrid.radius, style: .continuous)
                            .strokeBorder(.tint, lineWidth: 3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // A Zen folder's tab only unloads here, as its swipe does in the deck; closing is in the menu.
                    if tabMenu != nil, !hidden, !tab.fromZenFolder || tab.wasOpened {
                        Button(tab.fromZenFolder ? "Unload Tab" : "Close Tab",
                               systemImage: tab.fromZenFolder ? "moon.zzz" : "xmark", action: onClose)
                            .labelStyle(.iconOnly)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.primary)
                            .frame(width: 28, height: 28)
                            .background(.regularMaterial, in: .circle)
                            .padding(8)
                    }
                }
            HStack(spacing: 6) {
                SiteIcon(host: tab.url?.host(), size: 16, fetch: !tab.isPrivate)
                Text(tab.title.isEmpty ? tab.url?.host() ?? String(localized: "New Tab") : tab.title)
                    .font(.footnote)
                    .lineLimit(1)
                if tab.isPinned, !tab.fromZenFolder {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The title goes first: sliding over the next cell, the two titles ran into each other.
            .opacity(max(0, 1 - abs(dragX) / 30))
        }
        .frame(width: width)
        .scaleEffect(pressed && !reduceMotion ? 1.04 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)
        .offset(x: dragX)
        .zIndex(lifted ? 1 : 0)
        .contentShape(.rect)
        // On its way out it opens nothing: the tab is about to close.
        .allowsHitTesting(!leaving)
        .onTapGesture(perform: onSelect)
        .gesture(SidewaysPan(enabled: swipes, pressed: { pressed = $0 },
                             changed: { lifted = true; dragX = Self.follow($0) }, ended: endSwipe))
        .contextMenu {
            if let tabMenu {
                TabMenuItems(tab: tab, space: space, local: tab.spaceID == nil, menu: tabMenu)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gridCell")
        .onChange(of: leaving) { fly() }
    }

    /// Off to the left from wherever it is, and home once unmarked: a view SwiftUI revives for an Undo
    /// mid-removal still holds the old offset.
    private func fly() {
        lifted = true
        if leaving {
            withAnimation(.easeIn(duration: Self.flightTime)) { dragX = -flight }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { dragX = 0 } completion: {
                if !leaving { lifted = false }
            }
        }
    }

    /// Left with the finger; right only with growing resistance, as in Safari, since that way doesn't close.
    private static func follow(_ translation: CGFloat) -> CGFloat {
        translation < 0 ? translation : translation * 90 / (translation + 90)
    }

    private func endSwipe(translation: CGFloat, velocity: CGFloat) {
        // Flung back to the right, it stays, however far it got.
        guard (translation < -width / 3 && velocity < 300) || velocity < -800 else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { dragX = 0 } completion: { lifted = false }
            return
        }
        // It flies on from where the finger let it go.
        onClose()
    }
}

/// Starts only on a sideways move, either way, so the grid still scrolls. It also reports presses: a second
/// gesture for that took every touch from this one.
private struct SidewaysPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let pressed: (Bool) -> Void
    let changed: (CGFloat) -> Void
    let ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> PressPan {
        let pan = PressPan()
        pan.delegate = context.coordinator
        pan.swipes = enabled
        pan.pressed = pressed
        return pan
    }

    func updateUIGestureRecognizer(_ pan: PressPan, context: Context) {
        pan.swipes = enabled
        pan.pressed = pressed
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ pan: PressPan, context: Context) {
        let translation = pan.travel
        switch pan.state {
        case .changed: changed(translation)
        case .ended: ended(translation, pan.velocity(in: pan.view).x)
        case .cancelled, .failed: ended(0, 0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? PressPan, pan.swipes else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}

/// Says when a finger is on it, swipe or not. A scroll taking the touch cancels it and a failed pan
/// resets, so the cell always settles back.
private final class PressPan: UIPanGestureRecognizer {
    var swipes = true
    var pressed: (Bool) -> Void = { _ in }
    private var down = false
    private var start: CGPoint?

    /// From where the finger came down, not translation: a pan recognized late, after a busy main
    /// thread, counts only the moves after it, and a whole flick read as zero.
    var travel: CGFloat {
        guard let start else { return 0 }
        return location(in: view).x - start.x
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard !down else { return }
        down = true
        start = touches.first?.location(in: view)
        pressed(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        lift()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        lift()
    }

    override func reset() {
        super.reset()
        start = nil
        lift()
    }

    private func lift() {
        guard down else { return }
        down = false
        pressed(false)
    }
}

/// Rows of fixed-width cells, each row as tall as its tallest cell.
private struct GridRows: Layout {
    let columns: Int
    let spacing: CGFloat
    let rowSpacing: CGFloat

    /// Each cell measured once per change, not again for every proposal and for placing.
    struct Cache {
        var sizes: [CGSize]
        var rows: [CGFloat]
    }

    func makeCache(subviews: Subviews) -> Cache {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return Cache(sizes: sizes, rows: rowHeights(sizes))
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let sizes = cache.sizes
        let width = sizes.prefix(columns).reduce(0) { $0 + $1.width } + CGFloat(max(0, min(columns, sizes.count) - 1)) * spacing
        return CGSize(width: proposal.width ?? width,
                      height: cache.rows.reduce(0, +) + CGFloat(max(0, cache.rows.count - 1)) * rowSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY
        for (row, height) in cache.rows.enumerated() {
            var x = bounds.minX
            for index in row * columns..<min((row + 1) * columns, subviews.count) {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(cache.sizes[index]))
                x += cache.sizes[index].width + spacing
            }
            y += height + rowSpacing
        }
    }

    private func rowHeights(_ sizes: [CGSize]) -> [CGFloat] {
        stride(from: 0, to: sizes.count, by: columns).map { start in
            sizes[start..<min(start + columns, sizes.count)].map(\.height).max() ?? 0
        }
    }
}
