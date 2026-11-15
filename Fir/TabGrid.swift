import SwiftUI

/// The tab overview as a grid, as in Safari: a workspace's tabs side by side. A closed folder is one
/// cell; an open one gets its own row under its name.
struct TabGrid: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.isLandscape) private var landscape
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

    /// Smaller than the deck's: a cell is under half the screen wide. The page's mask lands on it.
    static let radius: CGFloat = 22
    private static let spacing: CGFloat = 14
    private static let margin: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let columns = max(2, Int((geo.size.width - 2 * Self.margin + Self.spacing) / (160 + Self.spacing)))
            let width = (geo.size.width - 2 * Self.margin - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns)
            // Upright, a cell keeps the top of the page; on its side the screen is wide, so the cell is too.
            let height = width * (landscape ? 0.7 : 1.38)
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
                            ForEach(rows(section.cells, columns: columns), id: \.first?.id) { row in
                                HStack(alignment: .top, spacing: Self.spacing) {
                                    ForEach(row) { cell($0, width: width, height: height) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Self.margin)
                    // Room above for a closed folder's pile.
                    .padding(.vertical, 20)
                }
                .scrollDisabled(!live)
                .onAppear { reveal(in: proxy) }
                // Under the page the grid keeps the selected cell in view, so the page has a cell to land on.
                .onChange(of: browser.selectedID) { if !holdsPosition { reveal(in: proxy) } }
                .onChange(of: holdsPosition) { if !holdsPosition { reveal(in: proxy) } }
                .onChange(of: hiddenTab) { if hiddenTab != nil { reveal(in: proxy) } }
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

    private func rows(_ cells: [Cell], columns: Int) -> [[Cell]] {
        stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0..<min($0 + columns, cells.count)]) }
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

    @ViewBuilder private func cell(_ cell: Cell, width: CGFloat, height: CGFloat) -> some View {
        switch cell {
        case .tab(let tab):
            tabCell(tab, width: width, height: height)
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

    private func tabCell(_ tab: BrowserTab, width: CGFloat, height: CGFloat) -> some View {
        GridCell(tab: tab, width: width, height: height, hidden: tab.id == hiddenTab,
                 selected: tab.id == browser.selectedID, live: live, tabMenu: tabMenu, space: space(tab),
                 onFrame: { onCardFrame(tab.id, $0) }) {
            browser.select(tab)
            onOpen()
        }
        .id(tab.id)
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
    let onFrame: (CGRect) -> Void
    let onSelect: () -> Void
    @State private var dragX: CGFloat = 0

    /// A Zen folder's tab only unloads, so one never opened has nothing to swipe away.
    private var swipes: Bool { tabMenu != nil && !hidden && (!tab.fromZenFolder || tab.wasOpened) }

    var body: some View {
        VStack(spacing: 8) {
            GridPicture(tab: tab, width: width, height: height, hidden: hidden, live: live, onFrame: onFrame)
                .overlay {
                    if selected, !hidden {
                        RoundedRectangle(cornerRadius: TabGrid.radius, style: .continuous)
                            .strokeBorder(.tint, lineWidth: 3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // A Zen folder's tab only unloads here, as its swipe does in the deck; closing is in the menu.
                    if let tabMenu, !hidden, !tab.fromZenFolder || tab.wasOpened {
                        Button(tab.fromZenFolder ? "Unload Tab" : "Close Tab",
                               systemImage: tab.fromZenFolder ? "moon.zzz" : "xmark") { tabMenu.close(tab) }
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
                Text(tab.title.isEmpty ? tab.url?.host() ?? "New Tab" : tab.title)
                    .font(.footnote)
                    .lineLimit(1)
                if tab.isPinned, !tab.fromZenFolder {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width)
        .offset(x: dragX)
        // Over the cell beside it while it slides.
        .zIndex(dragX == 0 ? 0 : 1)
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .gesture(LeftwardPan(enabled: swipes, changed: { dragX = $0 > 0 ? $0 / 4 : $0 }, ended: endSwipe))
        .contextMenu {
            if let tabMenu {
                TabMenuItems(tab: tab, space: space, local: tab.spaceID == nil, menu: tabMenu)
            }
        }
    }

    private func endSwipe(translation: CGFloat, velocity: CGFloat) {
        // Flung back to the right, it stays, however far it got.
        guard let tabMenu, (translation < -width / 3 && velocity < 300) || velocity < -800 else {
            withAnimation(.snappy) { dragX = 0 }
            return
        }
        withAnimation(.easeOut(duration: 0.2)) { dragX = -width * 3 } completion: {
            tabMenu.close(tab)
            // An unloaded Zen folder tab keeps its cell; it comes back.
            if tab.fromZenFolder { withAnimation(.snappy) { dragX = 0 } }
        }
    }
}

/// A pan that starts only when the finger moves left, so the grid still scrolls up and down under it.
private struct LeftwardPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let changed: (CGFloat) -> Void
    let ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.isEnabled = enabled
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        pan.isEnabled = enabled
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let translation = pan.translation(in: pan.view).x
        switch pan.state {
        case .changed: changed(translation)
        case .ended: ended(translation, pan.velocity(in: pan.view).x)
        case .cancelled, .failed: ended(0, 0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y)
        }
    }
}

