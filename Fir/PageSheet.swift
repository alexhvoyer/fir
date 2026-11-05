import MozillaAppServices
import SwiftUI
import Translation

/// The page's actions and this site's settings in one sheet, opened from the bar's menu button or a
/// long press on the address. Built from system controls throughout.
struct PageSheet: View {
    enum Action {
        case find, reader, pin, essential, translate(Locale.Language), showOriginal, downloads, settings
        case send(Device)
    }

    let tab: BrowserTab
    let isTranslated: Bool
    let sendTargets: [Device]
    /// The tab belongs to a synced Zen workspace, so Zen's pins and Essentials are on offer.
    var inZenSpace = false
    /// The chosen action; the caller runs it once the sheet is gone, so find and reader see the page.
    let onAction: (Action) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var languages: [Locale.Language] = []
    @State private var confirmForget = false
    @State private var copied = false
    @State private var reloads = 0
    @State private var detent = PresentationDetent.medium
    /// The sheet height that shows all the content.
    @State private var fit: CGFloat?
    /// Never full height: there iOS swaps the glass for an opaque background in one frame.
    private var top: PresentationDetent {
        fit.map { .height(min($0, Self.cap)) } ?? .fraction(0.9)
    }
    private static var cap: CGFloat {
        ((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 800) * 0.9
    }
    @AppStorage("translateTarget") private var targetID = ""

    private var settings: SiteSettings { .shared }
    private var site: SiteSettings.Entry { settings.entry(for: tab.pageURL) }

    var body: some View {
        NavigationStack {
            Form {
                Section { actions }
                Section {
                    translation
                    Stepper(value: Binding(get: { site.zoom }, set: setZoom), in: 0.5...3, step: 0.1) {
                        LabeledContent("Page Zoom", value: site.zoom.formatted(.percent.precision(.fractionLength(0))))
                    }
                    let extensions = ExtensionManager.shared.installed.filter(\.isEnabled)
                    if !extensions.isEmpty, !tab.isPrivate {
                        Menu {
                            ForEach(extensions) { item in
                                Button(item.name) { ExtensionManager.shared.performAction(item.id) }
                            }
                        } label: {
                            Label("Extensions", systemImage: "puzzlepiece.extension")
                        }
                        .tint(.primary)
                    }
                }
                Section("Settings for This Site") {
                    Toggle(isOn: binding(\.blockAds, reload: true)) {
                        Label("Block Ads & Trackers", systemImage: "checkmark.shield")
                    }
                    Toggle(isOn: binding(\.reader)) {
                        Label("Always Use Reader", systemImage: "doc.plaintext")
                    }
                    Toggle(isOn: binding(\.desktop, reload: true)) {
                        Label("Request Desktop Site", systemImage: "desktopcomputer")
                    }
                }
                if !tab.isPrivate {
                    Section {
                        Button("Forget This Website", systemImage: "trash", role: .destructive) { confirmForget = true }
                            // The icon follows the accent otherwise; destructive is red throughout.
                            .tint(.red)
                    }
                }
            }
            // The top height shows all the content, so the list needn't scroll. Scrolling took a swipe's
            // first points before the sheet moved, and slid the rows under the title.
            .scrollDisabled(fit.map { $0 <= Self.cap } ?? false)
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom
            } action: { _, height in
                // The bottom inset dips while the sheet resizes; the detent must not follow it mid-drag.
                guard height > (fit ?? 0) else { return }
                let wasTop = detent == top
                fit = height
                if wasTop { detent = top }
            }
            // The address with its two actions in one capsule, as in Lens, instead of a title bar with a
            // button in each corner.
            .safeAreaInset(edge: .top) { address }
            .background(SwipeBackEnabler())
            // The list never scrolls, so the edge effect only drew a dark band behind the capsule.
            .scrollEdgeEffectHidden(true, for: .top)
            .contentMargins(.top, 8, for: .scrollContent)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Downloads", systemImage: "arrow.down.circle") { finish(.downloads) }
                    Spacer()
                    Button("Settings", systemImage: "gear") { finish(.settings) }
                }
            }
            .confirmationDialog("Forget \(SiteSettings.site(tab.pageURL) ?? "this website")?",
                                isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) {
                    Task {
                        await settings.forget(tab.pageURL)
                        tab.webView.reload()
                        dismiss()
                    }
                }
            } message: {
                Text("Its cookies and data on this iPhone are removed, so you're signed out of it.")
            }
        }
        .presentationDetents([.medium, top], selection: $detent)
        .task { languages = await LanguageAvailability().supportedLanguages }
    }

    private var address: some View {
        HStack(spacing: 4) {
            // The lock and address open the connection's details, as in Lens.
            NavigationLink {
                ConnectionSecurityView(tab: tab)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: tab.pageURL?.scheme == "https" ? "lock.fill" : "lock.open.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(Self.shortAddress(tab.pageURL))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .disabled(tab.pageURL == nil)
            // Where Safari keeps them: Reader by the address, sharing beside it.
            if tab.isReaderable {
                Button("Reader", systemImage: "doc.plaintext") { finish(.reader) }
                    .frame(width: 36, height: 40)
            }
            if let url = tab.pageURL {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    .frame(width: 36, height: 40)
            }
            // The sheet stays open after both, so each answers with a haptic and its own symbol change.
            Button("Copy Link", systemImage: copied ? "checkmark" : "link") {
                UIPasteboard.general.url = tab.pageURL
                withAnimation { copied = true }
            }
            .contentTransition(.symbolEffect(.replace))
            .sensoryFeedback(.success, trigger: copied) { _, new in new }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { copied = false }
            }
            .frame(width: 36, height: 40)
            Button("Reload", systemImage: "arrow.clockwise") {
                tab.webView.reload()
                reloads += 1
            }
            .symbolEffect(.rotate, value: reloads)
            .sensoryFeedback(.impact(weight: .light), trigger: reloads)
            .frame(width: 36, height: 40)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(height: 52)
        .background(.fill.tertiary, in: .capsule)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    /// The address without its scheme, as Safari shows it while editing.
    private static func shortAddress(_ url: URL?) -> String {
        guard let url, let scheme = url.scheme else { return "" }
        return String(url.absoluteString.dropFirst(scheme.count + 3))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            action("Find", "doc.text.magnifyingglass") { finish(.find) }
            // A Zen folder's tab is already pinned there; unpinning would take it out of the folder.
            if tab.url != nil, !tab.fromZenFolder {
                action(tab.isPinned ? "Unpin" : "Pin", tab.isPinned ? "pin.slash" : "pin") { finish(.pin) }
                // Zen tells them apart: a pin stays in its space, an essential shows in all of them.
                if inZenSpace {
                    action(tab.zenEssentialID == nil ? "Essential" : "Remove",
                           tab.zenEssentialID == nil ? "star" : "star.slash") { finish(.essential) }
                }
            }
            if !tab.isPrivate, !sendTargets.isEmpty {
                Menu {
                    ForEach(sendTargets, id: \.id) { device in
                        Button(NewTabView.shortName(device.displayName)) { finish(.send(device)) }
                    }
                } label: {
                    tile("Send", "laptopcomputer.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
        }
        // Rounded squares, as Apple's own action tiles, not circles.
        .buttonBorderShape(.roundedRectangle(radius: 16))
        // Neutral, as in the system's own share sheet rows: the coral tint is for state, not every action.
        .tint(.secondary)
        .foregroundStyle(.primary)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { tile(title, symbol) }.buttonStyle(.bordered)
    }

    private func tile(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title3)
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
    }

    @ViewBuilder private var translation: some View {
        if isTranslated {
            Button("Show Original", systemImage: "character.book.closed") { finish(.showOriginal) }
                .foregroundStyle(.primary)
        } else {
            let target = targetID.isEmpty ? PageTranslator.readerLanguage : Locale.Language(identifier: targetID)
            HStack {
                Button("Translate to \(name(target))", systemImage: "translate") { finish(.translate(target)) }
                    .foregroundStyle(.primary)
                Spacer()
                Menu {
                    Picker("Translate To", selection: $targetID) {
                        Text("iPhone Language").tag("")
                        ForEach(languages, id: \.minimalIdentifier) { Text(name($0)).tag($0.minimalIdentifier) }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
            }
        }
    }

    private func name(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    private func setZoom(_ zoom: Double) {
        settings.update(tab.pageURL) { $0.zoom = zoom }
        tab.webView.pageZoom = zoom
    }

    /// A toggle for one of the site's settings; those that change how the page loads reload it.
    private func binding(_ key: WritableKeyPath<SiteSettings.Entry, Bool>, reload: Bool = false) -> Binding<Bool> {
        Binding(get: { site[keyPath: key] }, set: { value in
            settings.update(tab.pageURL) { $0[keyPath: key] = value }
            if reload { tab.webView.reload() }
        })
    }

    private func finish(_ action: Action) {
        dismiss()
        onAction(action)
    }
}
