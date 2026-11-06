import SwiftUI
import MozillaAppServices

/// Search field with the engine's suggestions, and matches from open tabs here, in Zen, on other
/// devices and in history.
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
    @State private var autofill: HistoryStore.Completion?
    @State private var showSignIn = false
    @FocusState private var focused: Bool
    @State private var expanded = false
    @State private var rising = false
    @State private var detent = Self.low
    private static let low = PresentationDetent.fraction(0.32)
    private static let tall = PresentationDetent.custom(TallDetent.self)

    private struct Match: Identifiable {
        enum Kind {
            case tab(BrowserTab)
            case zen(space: String, name: String)
            case device(name: String, mobile: Bool)
            case history
        }

        var id: String { url.absoluteString }
        let title: String
        let url: URL
        let kind: Kind

        var symbol: String {
            switch kind {
            case .tab: "square.on.square"
            case .zen: "rectangle.stack"
            case .device(_, let mobile): mobile ? "iphone" : "laptopcomputer"
            case .history: "clock"
            }
        }

        var place: String {
            switch kind {
            case .tab: "Open Tab"
            case .zen(_, let name): name
            case .device(let name, _): name
            case .history: "History"
            }
        }
    }

    var body: some View {
        // The start page until something is typed, as in Safari; typing switches to matches. Both stay
        // mounted: swapping them dropped the keyboard on the first letter.
        ZStack {
            results
            .padding(.top, 8)
            .shown(!showsStartPage)
            StartPage(spaceID: newTabSpace, onPullUp: expand, onOpen: { open($0) }, onOpenPin: { pin in
                browser.open(pin)
                onOpen()
                dismiss()
            })
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

    /// The Zen workspace a new tab opens in: the deck's, when it is one.
    private var zenSpace: String? {
        guard mode == .newTab, let space = browser.space,
              account.zenWorkspaces?.spaces.contains(where: { $0.id == space }) == true else { return nil }
        return space
    }

    private var results: some View {
        List {
            // The completed address on top, picked out as Go's target, as Safari's Top Hit.
            if let autofill, !showsStartPage {
                Button { open(autofill.url) } label: {
                    HStack(spacing: 12) {
                        SiteIcon(host: autofill.url.host(), size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(autofill.title ?? autofill.text).lineLimit(1)
                            Text(autofill.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .foregroundStyle(.primary)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.primary.opacity(0.08).clipShape(.rect(cornerRadius: 18, style: .continuous)))
            }
            if !suggestions.isEmpty {
                Section {
                    header("\(engine.name) Suggestions")
                    ForEach(suggestions, id: \.self) { text in
                        HStack(spacing: 12) {
                            Button { open(engine.url(for: text)) } label: {
                                ResultRow(symbol: "magnifyingglass", title: text)
                            }
                            // Into the field without searching, as in Safari: a start to keep typing from.
                            Button("Use \(text)", systemImage: "arrow.up.left.circle") { query = text }
                                .labelStyle(.iconOnly)
                                .imageScale(.large)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.primary)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            let found = matches
            if !found.isEmpty {
                Section {
                    header("History and Tabs")
                    ForEach(found) { match in
                        Button { select(match) } label: {
                            ResultRow(symbol: match.symbol, title: match.title,
                                      detail: [match.url.host(), match.place].compactMap { $0 }.joined(separator: " · "))
                        }
                        .foregroundStyle(.primary)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            if !account.isSignedIn {
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

    /// A row, not a section header: a plain list pins headers, and over the clear sheet they overlapped rows.
    private func header(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// Restarting on every keystroke cancels the previous fetch; the pause debounces typing.
    /// The last answers stay until new ones replace them, as in Safari: cleared on each keystroke, the
    /// suggestions vanished until the network answered and everything below jumped up and back.
    private func loadSuggestions() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text != browser.selected.url?.absoluteString else {
            (suggestions, historyMatches, autofill) = ([], [], nil)
            return
        }
        // A completion the new text no longer starts would be drawn wrong; it goes at once.
        if let autofill, !autofill.text.lowercased().hasPrefix(text.lowercased()) { self.autofill = nil }
        // The sheet's own privacy, not the tab behind it: a private new tab from a regular page showed history.
        if historyEnabled, !isPrivate {
            let (matches, completion) = await Task.detached {
                (HistoryStore.shared?.search(text, limit: 4) ?? [], HistoryStore.shared?.autofill(text))
            }.value
            // A later keystroke has started its own lookup; this answer is out of date.
            guard !Task.isCancelled else { return }
            (historyMatches, autofill) = (matches, completion)
        } else {
            (historyMatches, autofill) = ([], nil)
        }
        guard suggestionsEnabled else { suggestions = []; return }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let result = await engine.suggestions(for: text)
        guard !Task.isCancelled else { return }
        // Four, as in Safari: six pushed the tab and history matches under the keyboard.
        suggestions = Array(result.prefix(4))
    }

    /// Until something is typed, as in Safari: the field is empty, or still holds the page's address.
    private var showsStartPage: Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || (mode == .edit && text == browser.selected.url?.absoluteString)
    }

    /// The workspace the page will open in, as `open` decides it.
    private var newTabSpace: String? {
        if mode == .edit { return browser.selected.spaceID }
        return zenSpace ?? browser.space
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
                    if let autofill, autofill.text.count >= query.count {
                        (Text(query).foregroundStyle(.clear)
                            + Text(autofill.text.dropFirst(query.count)).foregroundStyle(.tint)
                            // The site's name after the address, as Safari shows it.
                            + Text(autofill.title.map { " — \($0)" } ?? "").foregroundStyle(.secondary))
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                }
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { open(autofill?.url ?? BrowserModel.url(from: query, engine: engine)) }
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

    /// Open tabs here, in Zen and on other devices, then history; one row per address. In memory,
    /// a few hundred rows at most, so filtering on each keystroke costs well under a millisecond.
    private var matches: [Match] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !showsStartPage, !text.isEmpty else { return [] }
        var found: [Match] = []
        var seen = Set<String>()
        func add(_ title: String, _ url: URL?, _ kind: Match.Kind, filter: Bool = true) {
            guard let url, !filter || title.localizedCaseInsensitiveContains(text)
                    || url.absoluteString.localizedCaseInsensitiveContains(text),
                  seen.insert(url.absoluteString).inserted else { return }
            found.append(Match(title: title, url: url, kind: kind))
        }
        for tab in browser.tabs.reversed() where !tab.isPrivate { add(tab.title, tab.url, .tab(tab)) }
        let zen = account.zenWorkspaces
        for space in zen?.spaces ?? [] {
            for tab in (zen?.essentials(in: space) ?? []) + space.tabs + space.folders.flatMap(\.tabs) {
                add(tab.title, tab.url, .zen(space: space.id, name: space.name))
            }
        }
        for client in account.recentClients {
            let device = Match.Kind.device(name: Self.shortName(client.clientName), mobile: client.deviceType == .mobile)
            for tab in client.remoteTabs { add(tab.title, tab.urlHistory.first.flatMap(URL.init(string:)), device) }
        }
        // Tabs first, as in Safari, but never so many that history drops out.
        found = Array(found.prefix(8))
        // Places matched these by its own rules, which a plain substring test would undo.
        for entry in historyMatches { add(entry.title, entry.url, .history, filter: false) }
        return found
    }

    private func select(_ match: Match) {
        switch match.kind {
        case .tab(let tab):
            browser.select(tab)
            onOpen()
            dismiss()
        case .zen(let space, _) where mode == .newTab && !isPrivate:
            browser.open(match.url, in: space)
            onOpen()
            dismiss()
        default:
            open(match.url)
        }
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        if mode == .edit {
            browser.selected.load(url)
        } else if let zenSpace {
            browser.open(url, in: zenSpace)
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

/// A result as Safari lists them: what kind it is, its title, then where it is.
private struct ResultRow: View {
    let symbol: String
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.quaternary, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? "Untitled" : title).lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
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
            // Under the app lock the keyboard would sit above it and type into the hidden field.
            guard !focused, !LockWindow.isShown else { return }
            focused = true
            // One run-loop pass after the sheet starts: in the same pass, sheet and keyboard layout held
            // the main thread for 110 ms; split, each costs about half. The keyboard still rises with the sheet.
            let field = Self.field(in: sheet.view)
            DispatchQueue.main.async { field?.becomeFirstResponder() }
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
