import SwiftUI
import MozillaAppServices

/// Search field plus tabs from three places: this iPhone, Zen workspaces, and each device's open tabs.
struct NewTabView: View {
    enum Mode: String, Identifiable {
        case newTab, edit
        var id: Self { self }
    }

    let mode: Mode
    /// Called after a tab was opened or switched to, as opposed to cancelling.
    let onOpen: () -> Void
    /// Hides this screen, opened or cancelled.
    let dismiss: () -> Void

    @Environment(BrowserModel.self) private var browser
    @Environment(AccountService.self) private var account
    @AppStorage(SettingsKey.searchEngine) private var engine = SearchEngine.duckDuckGo
    @AppStorage(SettingsKey.searchSuggestions) private var suggestionsEnabled = true
    @AppStorage(SettingsKey.historySuggestions) private var historyEnabled = true
    @State private var query = ""
    @State private var suggestions: [String] = []
    @State private var historyMatches: [HistoryStore.Entry] = []
    /// The rest of a visited site's address the query starts, shown after the typed text; Go opens it.
    @State private var autofill: String?
    @State private var source: Source?
    @State private var showSignIn = false
    @FocusState private var focused: Bool
    @State private var expanded = false
    @State private var rising = false
    @State private var detent = Self.low
    private static let low = PresentationDetent.fraction(0.32)
    private static let tall = PresentationDetent.custom(TallDetent.self)

    private enum Source: Hashable {
        case local
        case space(String)
        case device(String)
    }

    private struct Row: Identifiable {
        let id: String
        let title: String
        let url: URL?
        var localTab: BrowserTab?
    }

    private struct RowSection: Identifiable {
        let id: String
        let title: String?
        let rows: [Row]
    }

    var body: some View {
        // The start page until something is typed, as in Safari; typing switches to matches. Both stay
        // mounted: swapping them dropped the keyboard on the first letter.
        ZStack {
            VStack(spacing: 16) {
                sourceChips
                pinnedChips
                tabList
            }
            .padding(.top, 8)
            .shown(!showsStartPage)
            StartPage(spaceID: newTabSpace, insets: EdgeInsets(), background: .clear, onPullUp: expand) {
                open($0)
            }
            .shown(showsStartPage)
        }
        // While the sheet rises the finger's drag stops scrolling: both at once moved the content twice.
        .scrollDisabled(rising)
        // At the top of the sheet, as in Lens: what's below scrolls under the keyboard.
        .safeAreaInset(edge: .top) { searchBar }
        // One height at a time: low, then after a pull up only the full one, so a swipe down from
        // there closes rather than stopping half-way. Two from the start made the keyboard lift it to full.
        .presentationDetents(expanded ? [Self.tall] : [Self.low], selection: $detent)
        // A swipe down on a sheet with a keyboard only drops the keyboard; closing with it makes one motion.
        .background(SheetKeyboard {
            guard !rising else { return }
            dismiss()
        })
        .task {
            if mode == .edit { query = browser.selected.url?.absoluteString ?? "" }
            await account.sync()
        }
        .task(id: query) { await loadSuggestions() }
        .sheet(isPresented: $showSignIn) { SignInView() }
    }

    /// A new tab starts on the workspace it will open in, so its pins are at hand.
    private var currentSource: Source {
        if let source { return source }
        if mode == .newTab, let space = browser.space, account.zenWorkspaces?.spaces.contains(where: { $0.id == space }) == true {
            return .space(space)
        }
        return .local
    }

    private var sourceChips: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    chip(.local, label: "iPhone", systemImage: "iphone", tint: nil)
                    ForEach(account.zenWorkspaces?.spaces ?? []) { space in
                        chip(.space(space.id), label: space.name, emoji: space.icon, tint: space.color)
                    }
                    ForEach(account.recentClients, id: \.clientId) { client in
                        chip(.device(client.clientId), label: Self.shortName(client.clientName),
                             systemImage: "laptopcomputer", tint: nil)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ value: Source, label: String, systemImage: String? = nil,
                      emoji: String? = nil, tint: Color?) -> some View {
        let selected = currentSource == value
        return Button { withAnimation(.snappy) { source = value } } label: {
            HStack(spacing: 6) {
                if let emoji { Text(emoji) } else if let systemImage { Image(systemName: systemImage) }
                Text(label).lineLimit(1)
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 14)
            .frame(height: 38)
        }
        .foregroundStyle(.primary)
        .glassEffect(
            selected ? .regular.tint((tint ?? .accentColor).opacity(0.45)).interactive() : .regular.interactive(),
            in: .capsule
        )
    }

    @ViewBuilder private var pinnedChips: some View {
        let pinned = pinnedRows
        if !pinned.isEmpty {
            PinGrid(urls: pinned.map { ($0.id, $0.url) }, removeTitle: { _ in
                if case .space = currentSource { "Remove from Essentials" } else { nil }
            }) { open($0) }
                .padding(.horizontal, 20)
        }
    }

    private var tabList: some View {
        List {
            if !historyMatches.isEmpty {
                Section {
                    ForEach(historyMatches) { entry in
                        Button { open(entry.url) } label: { TabRow(title: entry.title, url: entry.url) }
                            .foregroundStyle(.primary)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions, id: \.self) { text in
                        Button { open(engine.url(for: text)) } label: {
                            Label(text, systemImage: "magnifyingglass").lineLimit(1)
                        }
                        .foregroundStyle(.primary)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            ForEach(filtered(sections)) { section in
                Section {
                    ForEach(section.rows) { row in
                        Button { select(row) } label: { TabRow(title: row.title, url: row.url) }
                            .foregroundStyle(.primary)
                            .listRowBackground(row.localTab?.id == browser.selectedID
                                               ? Color.primary.opacity(0.08) : .clear)
                    }
                } header: {
                    if let title = section.title {
                        Label(title, systemImage: "folder").font(.footnote.weight(.semibold))
                    }
                }
            }
            if !account.isSignedIn, currentSource == .local {
                Button("Sign in to see tabs from Zen", systemImage: "person.crop.circle") { showSignIn = true }
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Scrolling keeps the keyboard, as in Lens; the sheet's own swipe down closes both.
        .scrollDismissesKeyboard(.never)
        // Any pull up once past the top, not only the first: back at the low height the list stays scrolled.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: {
            if $1 > $0, $1 > 40 { expand() }
        }
    }

    /// Restarting on every keystroke cancels the previous fetch; the pause debounces typing.
    private func loadSuggestions() async {
        suggestions = []
        historyMatches = []
        autofill = nil
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text != browser.selected.url?.absoluteString else { return }
        if historyEnabled, !browser.selected.isPrivate {
            let (matches, completion) = await Task.detached {
                (HistoryStore.shared?.search(text, limit: 4) ?? [], HistoryStore.shared?.autofill(text))
            }.value
            // A later keystroke already cleared these; a stale answer must not come back.
            guard !Task.isCancelled else { return }
            (historyMatches, autofill) = (matches, completion)
        }
        guard suggestionsEnabled else { return }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let result = await engine.suggestions(for: text)
        guard !Task.isCancelled else { return }
        suggestions = Array(result.prefix(6))
    }

    /// Until something is typed, as in Safari: the field is empty, or still holds the page's address.
    private var showsStartPage: Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || (mode == .edit && text == browser.selected.url?.absoluteString)
    }

    /// The workspace the page will open in, as `open` decides it.
    private var newTabSpace: String? {
        if mode == .edit { return browser.selected.spaceID }
        if case .space(let id) = currentSource { return id }
        return browser.space
    }

    /// A new tab opens in the deck's workspace; editing keeps the current tab's.
    private var isPrivate: Bool {
        mode == .edit ? browser.selected.isPrivate : browser.space == BrowserModel.privateSpace
    }

    private var searchBar: some View {
        HStack {
            if isPrivate {
                PrivateMark()
            } else {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }
            TextField("Search or enter address", text: $query)
                .focused($focused)
                .overlay(alignment: .leading) {
                    if let autofill, autofill.count > query.count {
                        (Text(query).foregroundStyle(.clear)
                            + Text(autofill.dropFirst(query.count)).foregroundStyle(.tint))
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                }
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { open(BrowserModel.url(from: autofill ?? query, engine: engine)) }
                // Like Safari, the current address starts selected, so typing replaces it. SwiftUI's
                // TextSelection didn't apply on first focus; the UIKit field's range does.
                .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) {
                    guard mode == .edit, let field = $0.object as? UITextField else { return }
                    Task { field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument) }
                }
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            } else if UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs {
                // Paste and Go, as Safari offers: the system paste control reads the clipboard without
                // the "Allow Paste" prompt a plain read would raise.
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { return }
                    Task { @MainActor in open(BrowserModel.url(from: text, engine: engine)) }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .tint(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    /// Swaps the low height for the full one and moves there. UIKit does it in one animation: SwiftUI's
    /// own change snapped. SwiftUI's state catches up after, with the same height, so nothing moves then.
    private func expand() {
        // Once: each scroll step calls this, and restarting the animation stalled it short of the top.
        guard !expanded, !rising, let sheet = Self.topSheet() else { return }
        rising = true
        sheet.animateChanges {
            sheet.detents = [.custom(identifier: Self.tallID) { context in
                TallDetent.resolved = context.maximumDetentValue
                return context.maximumDetentValue
            }]
            sheet.selectedDetentIdentifier = Self.tallID
        }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            expanded = true
            detent = Self.tall
            rising = false
        }
    }

    private static let tallID = UISheetPresentationController.Detent.Identifier("tall")

    private static func topSheet() -> UISheetPresentationController? {
        var controller = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let next = controller?.presentedViewController { controller = next }
        return controller?.sheetPresentationController
    }

    // MARK: - Data

    private var pinnedRows: [Row] {
        switch currentSource {
        case .local:
            return []
        case .space(let id):
            let zen = account.zenWorkspaces
            return (zen?.essentials(in: zen?.spaces.first { $0.id == id }) ?? []).map(Self.row)
        case .device(let id):
            let client = account.remoteClients.first { $0.clientId == id }
            return (client?.remoteTabs.filter(\.pinned) ?? []).enumerated().map { Self.row($1, index: $0) }
        }
    }

    private var sections: [RowSection] {
        switch currentSource {
        case .local:
            let rows = browser.tabs.reversed().filter { !$0.isPrivate }.map {
                Row(id: $0.id.uuidString, title: $0.title, url: $0.url, localTab: $0)
            }
            return [RowSection(id: "local", title: nil, rows: rows)]
        case .space(let id):
            guard let space = account.zenWorkspaces?.spaces.first(where: { $0.id == id }) else { return [] }
            return [RowSection(id: "loose", title: nil, rows: space.tabs.map(Self.row))]
                + space.folders.map { RowSection(id: $0.id, title: $0.name, rows: $0.tabs.map(Self.row)) }
        case .device(let id):
            let client = account.remoteClients.first { $0.clientId == id }
            let rows = (client?.remoteTabs ?? [])
                .filter { !$0.pinned }
                .sorted { $0.lastUsed > $1.lastUsed }
                .enumerated()
                .map { Self.row($1, index: $0) }
            return [RowSection(id: "device", title: nil, rows: rows)]
        }
    }

    /// Filters only while typing a new search, not when the field holds the current URL.
    private func filtered(_ sections: [RowSection]) -> [RowSection] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text != browser.selected.url?.absoluteString else {
            return sections.filter { !$0.rows.isEmpty }
        }
        return sections.compactMap { section in
            let rows = section.rows.filter {
                $0.title.localizedCaseInsensitiveContains(text)
                    || ($0.url?.absoluteString.localizedCaseInsensitiveContains(text) ?? false)
            }
            return rows.isEmpty ? nil : RowSection(id: section.id, title: section.title, rows: rows)
        }
    }

    private static func row(_ tab: ZenWorkspaces.Tab) -> Row {
        Row(id: tab.id, title: tab.title, url: tab.url)
    }

    private static func row(_ tab: RemoteTabRecord, index: Int) -> Row {
        Row(id: "\(index)", title: tab.title, url: tab.urlHistory.first.flatMap(URL.init(string:)))
    }

    private func select(_ row: Row) {
        if let tab = row.localTab {
            browser.select(tab)
            onOpen()
            dismiss()
        } else {
            open(row.url)
        }
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        if mode == .edit {
            browser.selected.load(url)
        } else if case .space(let id) = currentSource {
            browser.open(url, in: id)
        } else {
            browser.open(url)
        }
        onOpen()
        dismiss()
    }

    /// "alexh's Zen on Alexanders-MacBook-Pro" -> "MacBook Pro"; "alexh's Zen on PC" -> "PC".
    static func shortName(_ clientName: String) -> String {
        guard let range = clientName.range(of: " on ", options: .backwards) else { return clientName }
        var device = String(clientName[range.upperBound...])
        if let mac = device.range(of: "MacBook") { device = String(device[mac.lowerBound...]) }
        return device.replacingOccurrences(of: "-", with: " ")
    }
}

/// The search sheet's full height: the value UIKit resolved in `expand`, so the two hand over unseen.
/// SwiftUI's own maximum came out higher, and the sheet jumped when its state caught up.
private struct TallDetent: CustomPresentationDetent {
    nonisolated(unsafe) static var resolved: CGFloat?

    static func height(in context: Context) -> CGFloat? { resolved ?? context.maxDetentValue }
}

private struct TabRow: View {
    let title: String
    let url: URL?

    var body: some View {
        HStack(spacing: 12) {
            SiteIcon(host: url?.host(), size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? "Untitled" : title).lineLimit(1)
                if let host = url?.host() {
                    Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

private extension View {
    /// Hides without removing, so state and focus around the view survive.
    func shown(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}

/// Makes the sheet's text field first responder as the sheet starts to appear, so UIKit raises the
/// keyboard with the presentation; focus set from SwiftUI then was dropped mid-slide. Reports the
/// keyboard going away, unless something was presented over the sheet or the app is leaving.
private struct SheetKeyboard: UIViewControllerRepresentable {
    let onDrop: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller(onDrop: onDrop) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.onDrop = onDrop }

    final class Controller: UIViewController {
        var onDrop: () -> Void
        private var focused = false
        private var observer: NSObjectProtocol?

        init(onDrop: @escaping () -> Void) {
            self.onDrop = onDrop
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError() }

        /// The sheet's own controller, the root of this one's parents.
        private var sheet: UIViewController {
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            return root
        }

        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            guard !focused else { return }
            focused = true
            Self.field(in: sheet.view)?.becomeFirstResponder()
            observer = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.sheet.presentedViewController == nil,
                          UIApplication.shared.applicationState == .active else { return }
                    self.onDrop()
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        private static func field(in view: UIView) -> UITextField? {
            if let field = view as? UITextField { return field }
            for subview in view.subviews {
                if let field = field(in: subview) { return field }
            }
            return nil
        }
    }
}
