import SwiftUI
import WebKit

/// One Adblock Plus filter list the user can turn on or off.
struct FilterList: Identifiable, Hashable {
    /// Lists in one group compile together, so a list's exceptions can undo another's rules there. Each
    /// group is its own WebKit rule list: one list is capped at 150,000 rules, and all lists together exceed it.
    enum Group: String, CaseIterable {
        case ads, trackers, cookies, annoyances
    }

    let id: String
    let name: String
    let detail: String
    let group: Group
    let url: URL
    /// Languages it covers; a regional list is on by default when the iPhone uses one of them.
    var languages: [String] = []

    var isRegional: Bool { !languages.isEmpty }
}

extension FilterList {
    static let catalog: [FilterList] = [
        FilterList(id: "easylist", name: "EasyList", detail: "Ads on English-language and international sites",
                   group: .ads, url: URL(string: "https://easylist.to/easylist/easylist.txt")!),
        FilterList(id: "easyprivacy", name: "EasyPrivacy", detail: "Trackers and analytics",
                   group: .trackers, url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
        FilterList(id: "cookies", name: "EasyList Cookie List", detail: "Cookie consent pop-ups",
                   group: .cookies, url: URL(string: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")!),
        FilterList(id: "annoyances", name: "Fanboy's Annoyance List",
                   detail: "Newsletter and open-in-app pop-ups, chat and notification prompts, social buttons",
                   group: .annoyances, url: URL(string: "https://easylist.to/easylist/fanboy-annoyance.txt")!),
        regional("ruadlist", "RuAdList", "Russian, Ukrainian, Kazakh, Uzbek",
                 "https://easylist-downloads.adblockplus.org/ruadlist.txt", ["ru", "uk", "kk", "uz", "be"]),
        regional("adguard-ru", "AdGuard Russian", "Russian",
                 "https://filters.adtidy.org/extension/ublock/filters/1.txt", ["ru"]),
        regional("easylist-de", "EasyList Germany", "German",
                 "https://easylist.to/easylistgermany/easylistgermany.txt", ["de"]),
        regional("liste-fr", "Liste FR", "French", "https://easylist-downloads.adblockplus.org/liste_fr.txt", ["fr"]),
        regional("easylist-it", "EasyList Italy", "Italian",
                 "https://easylist-downloads.adblockplus.org/easylistitaly.txt", ["it"]),
        regional("easylist-es", "EasyList Spanish", "Spanish",
                 "https://easylist-downloads.adblockplus.org/easylistspanish.txt", ["es"]),
        regional("easylist-pt", "EasyList Portuguese", "Portuguese",
                 "https://easylist-downloads.adblockplus.org/easylistportuguese.txt", ["pt"]),
        regional("easylist-nl", "EasyList Dutch", "Dutch",
                 "https://easylist-downloads.adblockplus.org/easylistdutch.txt", ["nl"]),
        regional("easylist-pl", "EasyList Polish", "Polish",
                 "https://easylist-downloads.adblockplus.org/easylistpolish.txt", ["pl"]),
        regional("easylist-lt", "EasyList Lithuania", "Lithuanian",
                 "https://easylist-downloads.adblockplus.org/easylistlithuania.txt", ["lt"]),
        regional("adguard-tr", "AdGuard Turkish", "Turkish",
                 "https://filters.adtidy.org/extension/ublock/filters/13.txt", ["tr"]),
        regional("liste-ar", "Liste AR", "Arabic", "https://easylist-downloads.adblockplus.org/Liste_AR.txt", ["ar"]),
        regional("easylist-he", "EasyList Hebrew", "Hebrew",
                 "https://easylist-downloads.adblockplus.org/israellist.txt", ["he"]),
        regional("easylist-zh", "EasyList China", "Chinese",
                 "https://easylist-downloads.adblockplus.org/easylistchina.txt", ["zh"]),
        regional("adguard-ja", "AdGuard Japanese", "Japanese",
                 "https://filters.adtidy.org/extension/ublock/filters/7.txt", ["ja"]),
        regional("koreanlist", "KoreanList", "Korean",
                 "https://easylist-downloads.adblockplus.org/koreanlist.txt", ["ko"]),
        regional("abpindo", "ABPindo", "Indonesian", "https://easylist-downloads.adblockplus.org/abpindo.txt", ["id"]),
        regional("abpvn", "ABPVN", "Vietnamese", "https://easylist-downloads.adblockplus.org/abpvn.txt", ["vi"]),
    ]

    private static func regional(_ id: String, _ name: String, _ detail: String, _ url: String,
                                 _ languages: [String]) -> FilterList {
        FilterList(id: id, name: name, detail: detail, group: .ads, url: URL(string: url)!, languages: languages)
    }

    /// On at first: ads, trackers and cookie pop-ups, plus the lists for the iPhone's languages.
    static var defaultSelection: Set<String> {
        let languages = Set(Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier })
        var ids: Set<String> = ["easylist", "easyprivacy", "cookies"]
        for list in catalog where !Set(list.languages).isDisjoint(with: languages) { ids.insert(list.id) }
        return ids
    }
}

/// Blocks ads, trackers and pop-ups with WebKit rule lists built from the chosen filter lists. Compiled
/// lists are cached by WebKit; the sources are fetched again once a week.
@MainActor
@Observable
final class ContentBlocker {
    static let shared = ContentBlocker()

    enum State: Equatable {
        case off, loading, ready(rules: Int), failed(String)
    }

    private(set) var state = State.off
    private(set) var updated: Date?
    private(set) var selection: Set<String>
    @ObservationIgnored private var ruleLists: [FilterList.Group: (list: WKContentRuleList, rules: Int)] = [:]
    @ObservationIgnored private let webViews = NSHashTable<WKWebView>.weakObjects()
    /// Rebuilds run one at a time, so quick toggles can't race to the store.
    @ObservationIgnored private var work: Task<Void, Never>?

    private static let updatedKey = "contentBlockerUpdated"
    private static let selectionKey = "filterLists"
    /// Set by versions that compiled EasyList, EasyPrivacy and RuAdList as one list.
    private static let legacySourcesKey = "contentBlockerSources"

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.blockAds, default: true) }

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.stringArray(forKey: Self.selectionKey) {
            selection = Set(saved)
        } else {
            var initial = FilterList.defaultSelection
            // Those versions always blocked with RuAdList; keep it for them.
            if defaults.string(forKey: Self.legacySourcesKey) != nil { initial.insert("ruadlist") }
            selection = initial
            defaults.set(Array(initial), forKey: Self.selectionKey)
        }
    }

    /// Every web view registers on creation, so turning blocking on or off reaches open tabs too. A page's
    /// popup shares its opener's content controller, which already has the rules.
    func attach(_ webView: WKWebView, addRules: Bool = true) {
        webViews.add(webView)
        guard addRules, isEnabled else { return }
        for (list, _) in ruleLists.values { webView.configuration.userContentController.add(list) }
        webView.configuration.userContentController.addUserScript(Self.layoutFixes)
    }

    /// On dtf.ru and vc.ru the header ad keeps a 42 pt slot and raises the header to 102 pt; hiding the
    /// ad leaves an empty strip. This hides the slot and resets the height. Rule lists can't set styles.
    private static let layoutFixes = WKUserScript(source: """
        if (/(^|\\.)(dtf|vc)\\.ru$/.test(location.hostname)) {
          const css = document.createElement('style');
          css.textContent = '.header__distribution { display: none !important } :root { --layout-header-height: var(--layout-header-height-default) !important }';
          document.head.append(css);
        }
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)

    func start() async {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.legacySourcesKey) != nil {
            try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: "zentabs-blocklist")
            for key in [Self.legacySourcesKey, "contentBlockerRules"] { defaults.removeObject(forKey: key) }
        }
        guard isEnabled else { state = .off; return }
        updated = UserDefaults.standard.object(forKey: Self.updatedKey) as? Date
        let fresh = updated.map { $0.timeIntervalSinceNow > -7 * 24 * 3600 } ?? false
        await run { await self.rebuild(FilterList.Group.allCases, fetch: !fresh) }
    }

    /// Fetches every chosen list again.
    func update() async {
        await run { await self.rebuild(FilterList.Group.allCases, fetch: true) }
    }

    func isSelected(_ list: FilterList) -> Bool { selection.contains(list.id) }

    /// Applies from the next page load, as WebKit only checks rules when loading.
    func setSelected(_ selected: Bool, _ list: FilterList) async {
        if selected { selection.insert(list.id) } else { selection.remove(list.id) }
        UserDefaults.standard.set(Array(selection), forKey: Self.selectionKey)
        guard isEnabled else { return }
        await run { await self.rebuild([list.group], fetch: false) }
    }

    func setEnabled(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: SettingsKey.blockAds)
        if enabled {
            await start()
        } else {
            for webView in webViews.allObjects {
                webView.configuration.userContentController.removeAllContentRuleLists()
                webView.configuration.userContentController.removeAllUserScripts()
                // Removing scripts can't spare one; the password and video scripts go back in.
                webView.configuration.userContentController.addUserScript(PasswordAutofill.script)
                webView.configuration.userContentController.addUserScript(BrowserTab.pictureInPictureReturn)
            }
            ruleLists = [:]
            state = .off
        }
    }

    /// Turns blocking off for one web view while it shows a site the user exempted, and back on after.
    func setBlocking(_ enabled: Bool, for webView: WKWebView) {
        guard isEnabled, !ruleLists.isEmpty else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if enabled { for (list, _) in ruleLists.values { controller.add(list) } }
    }

    private func run(_ job: @escaping @MainActor () async -> Void) async {
        let previous = work
        let next = Task { @MainActor in
            await previous?.value
            await job()
        }
        work = next
        await next.value
    }

    /// Compiles each group from its chosen lists, reusing WebKit's cached copy when the lists are the same
    /// and `fetch` is off. A group whose lists can't be fetched keeps its cached rules.
    private func rebuild(_ groups: [FilterList.Group], fetch: Bool) async {
        if ruleLists.isEmpty { state = .loading }
        let store = WKContentRuleListStore.default()!
        var failure: String?
        var fetched = false
        for group in groups {
            let lists = FilterList.catalog.filter { $0.group == group && selection.contains($0.id) }
            // The app's first name; a new one would recompile every list and orphan the old ones.
            let identifier = "zentabs-\(group.rawValue)"
            let sourcesKey = "contentBlockerSources.\(group.rawValue)"
            let sourcesID = lists.map(\.id).joined(separator: " ")
            guard !lists.isEmpty else {
                ruleLists[group] = nil
                try? await store.removeContentRuleList(forIdentifier: identifier)
                UserDefaults.standard.removeObject(forKey: sourcesKey)
                continue
            }
            let defaults = UserDefaults.standard
            if !fetch, defaults.string(forKey: sourcesKey) == sourcesID,
               let cached = try? await store.contentRuleList(forIdentifier: identifier) {
                ruleLists[group] = (cached, defaults.integer(forKey: "\(sourcesKey).rules"))
                continue
            }
            do {
                var texts: [String] = []
                for list in lists {
                    let (data, response) = try await URLSession.shared.data(from: list.url)
                    let text = String(decoding: data, as: UTF8.self)
                    // A captive portal or a rate-limited host answers with a web page; compiled, it replaced the rules.
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          !text.prefix(512).lowercased().contains("<html") else { throw URLError(.badServerResponse) }
                    texts.append(text)
                }
                let (list, count) = try await Self.compile(texts, identifier: identifier)
                ruleLists[group] = (list, count)
                defaults.set(sourcesID, forKey: sourcesKey)
                defaults.set(count, forKey: "\(sourcesKey).rules")
                fetched = true
            } catch {
                failure = error.localizedDescription
                if ruleLists[group] == nil, let cached = try? await store.contentRuleList(forIdentifier: identifier) {
                    ruleLists[group] = (cached, defaults.integer(forKey: "\(sourcesKey).rules"))
                }
            }
        }
        if fetched {
            updated = .now
            UserDefaults.standard.set(updated, forKey: Self.updatedKey)
        }
        guard isEnabled else { return }
        if ruleLists.isEmpty, let failure {
            state = .failed(failure)
        } else {
            apply()
        }
    }

    /// One invalid hiding selector fails a whole list; then it compiles with network rules alone.
    private static func compile(_ texts: [String], identifier: String) async throws -> (WKContentRuleList, Int) {
        let output = await Task.detached(priority: .utility) { FilterListConverter.convert(texts) }.value
        for includeHiding in [true, false] {
            let rules = output.rules(includeHiding: includeHiding)
            guard let json = await Task.detached(priority: .utility, operation: { FilterListConverter.json(rules) }).value
            else { continue }
            if let list = try? await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) {
                return (list, rules.count)
            }
        }
        throw BlockerError.compileFailed
    }

    private func apply() {
        for webView in webViews.allObjects {
            let controller = webView.configuration.userContentController
            controller.removeAllContentRuleLists()
            for (list, _) in ruleLists.values { controller.add(list) }
            // Re-enabling must bring the script back to open tabs too.
            controller.removeAllUserScripts()
            controller.addUserScript(Self.layoutFixes)
            controller.addUserScript(PasswordAutofill.script)
            controller.addUserScript(BrowserTab.pictureInPictureReturn)
        }
        state = .ready(rules: ruleLists.values.reduce(0) { $0 + $1.rules })
    }

    enum BlockerError: LocalizedError {
        case compileFailed
        var errorDescription: String? { "The filter lists didn't compile." }
    }
}
