import SwiftUI
import WebKit

/// One Adblock Plus filter list the user can turn on or off.
struct FilterList: Identifiable, Hashable {
    /// A catalog group's lists compile together, so one list's exceptions can undo another's rules. Each group
    /// is its own WebKit rule list, capped at 150,000 rules; added lists compile alone.
    enum Group: String, CaseIterable {
        case ads, trackers, cookies, annoyances
        /// Lists the user added by address.
        case added
    }

    let id: String
    let name: String
    let detail: String
    let group: Group
    let url: URL
    /// Languages it covers; a regional list is on by default when the iPhone uses one of them.
    var languages: [String] = []

    var isRegional: Bool { !languages.isEmpty }

    /// What compiles together: a group of the catalog, or one added list alone, so a broken or huge list
    /// breaks nothing else and has the whole rule limit to itself.
    var unit: String { group == .added ? "added-\(id)" : group.rawValue }
}

extension FilterList {
    static let catalog: [FilterList] = [
        FilterList(id: "easylist", name: "EasyList", detail: String(localized: "Ads on English-language and international sites"),
                   group: .ads, url: URL(string: "https://easylist.to/easylist/easylist.txt")!),
        FilterList(id: "easyprivacy", name: "EasyPrivacy", detail: String(localized: "Trackers and analytics"),
                   group: .trackers, url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
        FilterList(id: "cookies", name: "EasyList Cookie List", detail: String(localized: "Cookie consent pop-ups"),
                   group: .cookies, url: URL(string: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")!),
        FilterList(id: "annoyances", name: "Fanboy's Annoyance List",
                   detail: String(localized: "Newsletter and open-in-app pop-ups, chat and notification prompts, social buttons"),
                   group: .annoyances, url: URL(string: "https://easylist.to/easylist/fanboy-annoyance.txt")!),
        regional("ruadlist", "RuAdList",
                 "https://easylist-downloads.adblockplus.org/ruadlist.txt", ["ru", "uk", "kk", "uz", "be"]),
        regional("adguard-ru", "AdGuard Russian",
                 "https://filters.adtidy.org/extension/ublock/filters/1.txt", ["ru"]),
        regional("easylist-de", "EasyList Germany",
                 "https://easylist.to/easylistgermany/easylistgermany.txt", ["de"]),
        regional("liste-fr", "Liste FR", "https://easylist-downloads.adblockplus.org/liste_fr.txt", ["fr"]),
        regional("easylist-it", "EasyList Italy",
                 "https://easylist-downloads.adblockplus.org/easylistitaly.txt", ["it"]),
        regional("easylist-es", "EasyList Spanish",
                 "https://easylist-downloads.adblockplus.org/easylistspanish.txt", ["es"]),
        regional("easylist-pt", "EasyList Portuguese",
                 "https://easylist-downloads.adblockplus.org/easylistportuguese.txt", ["pt"]),
        regional("easylist-nl", "EasyList Dutch",
                 "https://easylist-downloads.adblockplus.org/easylistdutch.txt", ["nl"]),
        regional("easylist-pl", "EasyList Polish",
                 "https://easylist-downloads.adblockplus.org/easylistpolish.txt", ["pl"]),
        regional("easylist-lt", "EasyList Lithuania",
                 "https://easylist-downloads.adblockplus.org/easylistlithuania.txt", ["lt"]),
        regional("adguard-tr", "AdGuard Turkish",
                 "https://filters.adtidy.org/extension/ublock/filters/13.txt", ["tr"]),
        regional("liste-ar", "Liste AR", "https://easylist-downloads.adblockplus.org/Liste_AR.txt", ["ar"]),
        regional("easylist-he", "EasyList Hebrew",
                 "https://easylist-downloads.adblockplus.org/israellist.txt", ["he"]),
        regional("easylist-zh", "EasyList China",
                 "https://easylist-downloads.adblockplus.org/easylistchina.txt", ["zh"]),
        regional("adguard-ja", "AdGuard Japanese",
                 "https://filters.adtidy.org/extension/ublock/filters/7.txt", ["ja"]),
        regional("koreanlist", "KoreanList",
                 "https://easylist-downloads.adblockplus.org/koreanlist.txt", ["ko"]),
        regional("abpindo", "ABPindo", "https://easylist-downloads.adblockplus.org/abpindo.txt", ["id"]),
        regional("abpvn", "ABPVN", "https://easylist-downloads.adblockplus.org/abpvn.txt", ["vi"]),
    ]

    /// Described by the languages it covers, named in the iPhone's own language.
    private static func regional(_ id: String, _ name: String, _ url: String, _ languages: [String]) -> FilterList {
        let names = languages.compactMap { Locale.current.localizedString(forLanguageCode: $0) }.formatted(.list(type: .and))
        return FilterList(id: id, name: name, detail: names.prefix(1).uppercased() + names.dropFirst(), group: .ads,
                          url: URL(string: url)!, languages: languages)
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
    /// Why the last update of the lists left some out, if it did.
    private(set) var lastFailure: String?
    private(set) var updated: Date?
    private(set) var selection: Set<String>
    /// Lists the user added by address, in the order added.
    private(set) var addedLists: [FilterList]
    /// Rules compiled and the last error, by unit, to show beside each added list.
    private(set) var unitRules: [String: Int] = [:]
    private(set) var unitFailures: [String: String] = [:]
    @ObservationIgnored private var ruleLists: [String: (list: WKContentRuleList, rules: Int)] = [:]
    @ObservationIgnored private let webViews = NSHashTable<WKWebView>.weakObjects()
    /// Rebuilds run one at a time, so quick toggles can't race to the store.
    @ObservationIgnored private var work: Task<Void, Never>?

    private static let updatedKey = "contentBlockerUpdated"
    private static let selectionKey = "filterLists"
    private static let addedKey = "addedFilterLists"
    /// WebKit refuses a rule list with more rules than this.
    private static let ruleLimit = 150_000
    private static let downloadLimit = 30_000_000
    /// Above EasyList's lines several times over, yet bounded in memory.
    private static let lineLimit = 400_000
    private static let buildingKey = "contentBlockerBuilding"

    /// Lines as the converter splits them: LF, CRLF and a lone CR each end one.
    private static func lineCount(_ text: String) -> Int {
        var count = 0, afterCR = false
        for byte in text.utf8 {
            if byte == 13 || (byte == 10 && !afterCR) { count += 1 }
            afterCR = byte == 13
        }
        return count
    }

    /// Capped, so an endless or compressed-bomb answer never fills memory; ephemeral, so the list's host
    /// can't set a cookie and recognise the phone at each weekly fetch.
    private static func download(_ url: URL) async throws -> (Data, URLResponse) {
        let receiver = LimitedDownload(limit: downloadLimit)
        let session = URLSession(configuration: .ephemeral, delegate: receiver, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            receiver.continuation = continuation
            session.dataTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)).resume()
        }
    }

    private struct Added: Codable {
        let id: String
        let name: String
        let url: URL
    }

    var allLists: [FilterList] { FilterList.catalog + addedLists }
    private var allUnits: [String] {
        FilterList.Group.allCases.filter { $0 != .added }.map(\.rawValue) + addedLists.map(\.unit)
    }
    /// Set by versions that compiled EasyList, EasyPrivacy and RuAdList as one list.
    private static let legacySourcesKey = "contentBlockerSources"

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.blockAds, default: true) }

    private init() {
        let defaults = UserDefaults.standard
        let added = defaults.data(forKey: Self.addedKey).flatMap { try? JSONDecoder().decode([Added].self, from: $0) } ?? []
        addedLists = added.map { Self.list($0) }
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
        let crashed = defaults.string(forKey: Self.buildingKey)
        if let crashed {
            defaults.removeObject(forKey: Self.buildingKey)
            for list in addedLists where list.unit == crashed { selection.remove(list.id) }
            defaults.set(Array(selection), forKey: Self.selectionKey)
        }
        guard isEnabled else { state = .off; return }
        updated = UserDefaults.standard.object(forKey: Self.updatedKey) as? Date
        let fresh = updated.map { $0.timeIntervalSinceNow > -7 * 24 * 3600 } ?? false
        // Cached rules first: a weekly refresh mustn't leave pages unblocked while it downloads.
        await run { await self.rebuild(self.allUnits, fetch: self.updated == nil) }
        // After the rebuild, which clears the failures of lists that are off.
        if let crashed { unitFailures[crashed] = BlockerError.closedFir.localizedDescription }
        if updated != nil, !fresh { await update() }
    }

    /// Fetches every chosen list again.
    func update() async {
        await run { await self.rebuild(self.allUnits, fetch: true) }
    }

    func isSelected(_ list: FilterList) -> Bool { selection.contains(list.id) }

    /// Applies from the next page load, as WebKit only checks rules when loading.
    func setSelected(_ selected: Bool, _ list: FilterList) async {
        if selected { selection.insert(list.id) } else { selection.remove(list.id) }
        UserDefaults.standard.set(Array(selection), forKey: Self.selectionKey)
        guard isEnabled else { return }
        await run { await self.rebuild([list.unit], fetch: false) }
    }

    enum AddError: LocalizedError {
        case notSecure, duplicate
        var errorDescription: String? {
            switch self {
            case .notSecure: String(localized: "Enter the list's full address, starting with https://.")
            case .duplicate: String(localized: "This list is already in Filter Lists.")
            }
        }
    }

    /// Adds a filter list by its address and turns it on; it's fetched now and weekly with the rest.
    func addList(_ address: String) async throws {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else { throw AddError.notSecure }
        guard !allLists.contains(where: { Self.same($0.url, url) }) else { throw AddError.duplicate }
        // Until the list's own title arrives; a script's name, like serverlist.php, says less than its site.
        let file = url.lastPathComponent
        let name = url.query() == nil && file.count > 1 ? file : host
        let list = Self.list(Added(id: UUID().uuidString, name: name, url: url))
        addedLists.append(list)
        saveAdded()
        selection.insert(list.id)
        UserDefaults.standard.set(Array(selection), forKey: Self.selectionKey)
        guard isEnabled else { return }
        await run { await self.rebuild([list.unit], fetch: true) }
    }

    func removeList(_ list: FilterList) async {
        addedLists.removeAll { $0.id == list.id }
        saveAdded()
        selection.remove(list.id)
        UserDefaults.standard.set(Array(selection), forKey: Self.selectionKey)
        // With no lists left, rebuilding the unit deletes its compiled rules.
        await run { await self.rebuild([list.unit], fetch: false) }
    }

    /// Hosts ignore case, and a trailing slash names the same file.
    private static func same(_ a: URL, _ b: URL) -> Bool {
        let key = { (url: URL) in
            "\(url.host()?.lowercased() ?? "")\(url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/")))?\(url.query() ?? "")"
        }
        return key(a) == key(b)
    }

    private static func list(_ added: Added) -> FilterList {
        FilterList(id: added.id, name: added.name, detail: added.url.host() ?? "", group: .added, url: added.url)
    }

    private func saveAdded() {
        let saved = addedLists.map { Added(id: $0.id, name: $0.name, url: $0.url) }
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Self.addedKey)
    }

    /// A list's own name, from its "! Title:" header.
    private func rename(_ list: FilterList, from text: String) {
        // By isNewline: many lists end lines in CRLF, which a split on "\n" never meets.
        let line = text.prefix(4000).split(whereSeparator: \.isNewline).first { $0.hasPrefix("! Title:") }
        // Without control and format characters, which could reverse or hide parts of the name.
        let visible = line.map { String(String.UnicodeScalarView($0.unicodeScalars.filter {
            ![.control, .format].contains($0.properties.generalCategory)
        })) }
        guard let title = visible?.dropFirst("! Title:".count).trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let index = addedLists.firstIndex(where: { $0.id == list.id }) else { return }
        addedLists[index] = FilterList(id: list.id, name: String(title.prefix(60)), detail: list.detail, group: .added, url: list.url)
        saveAdded()
    }

    func setEnabled(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: SettingsKey.blockAds)
        if enabled {
            await start()
        } else {
            for webView in webViews.allObjects {
                webView.configuration.userContentController.removeAllContentRuleLists()
                webView.configuration.userContentController.removeAllUserScripts()
                Self.addAppScripts(to: webView.configuration.userContentController)
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
    private func rebuild(_ units: [String], fetch: Bool) async {
        if ruleLists.isEmpty || fetch { state = .loading }
        let store = WKContentRuleListStore.default()!
        var failure: String?
        var fetched = false
        for unit in units {
            let lists = allLists.filter { $0.unit == unit && selection.contains($0.id) }
            // The app's first name; a new one would recompile every list and orphan the old ones.
            let identifier = "zentabs-\(unit)"
            let sourcesKey = "contentBlockerSources.\(unit)"
            let sourcesID = lists.map(\.id).joined(separator: " ")
            guard !lists.isEmpty else {
                ruleLists[unit] = nil
                unitRules[unit] = nil
                unitFailures[unit] = nil
                try? await store.removeContentRuleList(forIdentifier: identifier)
                UserDefaults.standard.removeObject(forKey: sourcesKey)
                UserDefaults.standard.removeObject(forKey: "\(sourcesKey).rules")
                continue
            }
            let defaults = UserDefaults.standard
            if !fetch, defaults.string(forKey: sourcesKey) == sourcesID,
               let cached = try? await store.contentRuleList(forIdentifier: identifier) {
                ruleLists[unit] = (cached, defaults.integer(forKey: "\(sourcesKey).rules"))
                unitRules[unit] = ruleLists[unit]?.rules
                continue
            }
            // Cleared when done: still set at launch, building this list closed Fir, so it is turned off.
            if unit.hasPrefix("added-") { defaults.set(unit, forKey: Self.buildingKey) }
            defer { defaults.removeObject(forKey: Self.buildingKey) }
            do {
                var texts: [String] = []
                var missed: (any Error)?
                for list in lists {
                    do {
                        let (data, response) = try await Self.download(list.url)
                        let text = String(decoding: data, as: UTF8.self)
                        // A captive portal or a rate-limited host answers with a web page; compiled, it replaced the rules.
                        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                              !text.prefix(512).lowercased().contains("<html") else { throw BlockerError.notAList }
                        // Each line becomes a rule held in memory before the rule limit is checked.
                        if list.group == .added, Self.lineCount(text) > Self.lineLimit {
                            throw BlockerError.tooLarge
                        }
                        texts.append(text)
                        if list.group == .added { rename(list, from: text) }
                    } catch {
                        missed = error
                    }
                }
                let hasRules = ruleLists[unit] != nil
                if let missed, hasRules || texts.isEmpty { throw missed }
                let (list, count) = try await Self.compile(texts, identifier: identifier)
                ruleLists[unit] = (list, count)
                unitRules[unit] = count
                unitFailures[unit] = nil
                if let missed {
                    // Better some rules than none. No sources saved, so the next launch fetches the rest.
                    failure = missed.localizedDescription
                    continue
                }
                defaults.set(sourcesID, forKey: sourcesKey)
                defaults.set(count, forKey: "\(sourcesKey).rules")
                fetched = true
            } catch {
                failure = error.localizedDescription
                unitFailures[unit] = failure
                if ruleLists[unit] == nil, let cached = try? await store.contentRuleList(forIdentifier: identifier) {
                    ruleLists[unit] = (cached, defaults.integer(forKey: "\(sourcesKey).rules"))
                }
                // An added list that never worked goes off, or every launch would download it again.
                if unit.hasPrefix("added-"), ruleLists[unit] == nil {
                    for list in lists { selection.remove(list.id) }
                    defaults.set(Array(selection), forKey: Self.selectionKey)
                }
            }
        }
        // Fetching one added list says nothing about when the rest were.
        let everything = Set(units) == Set(allUnits)
        if fetched, everything {
            updated = .now
            UserDefaults.standard.set(updated, forKey: Self.updatedKey)
        }
        if fetch, everything { lastFailure = failure }
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
        var tooLarge = false
        for includeHiding in [true, false] {
            let rules = output.rules(includeHiding: includeHiding)
            guard rules.count <= ruleLimit else { tooLarge = true; continue }
            guard let json = await Task.detached(priority: .utility, operation: { FilterListConverter.json(rules) }).value
            else { continue }
            if let list = try? await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) {
                return (list, rules.count)
            }
        }
        throw tooLarge ? BlockerError.tooLarge : BlockerError.compileFailed
    }

    private func apply() {
        for webView in webViews.allObjects {
            let controller = webView.configuration.userContentController
            controller.removeAllContentRuleLists()
            let site = SiteSettings.shared.entry(for: webView.url, isPrivate: !webView.configuration.websiteDataStore.isPersistent)
            if site.blockAds { for (list, _) in ruleLists.values { controller.add(list) } }
            // Re-enabling must bring the script back to open tabs too.
            controller.removeAllUserScripts()
            controller.addUserScript(Self.layoutFixes)
            Self.addAppScripts(to: controller)
        }
        state = .ready(rules: ruleLists.values.reduce(0) { $0 + $1.rules })
    }

    /// Removing scripts can't spare one, so every other script the app adds goes back in here.
    private static func addAppScripts(to controller: WKUserContentController) {
        controller.addUserScript(PasswordAutofill.script)
        controller.addUserScript(BrowserTab.pictureInPictureReturn)
        controller.addUserScript(CameraClearance.script)
    }

    enum BlockerError: LocalizedError {
        case compileFailed, tooLarge, tooBig, notAList, closedFir
        var errorDescription: String? {
            switch self {
            case .tooBig: String(localized: "The file is over 30 MB, far bigger than a filter list.")
            case .closedFir: String(localized: "Fir closed before this list was ready, so it was turned off. Turn it on to try again.")
            case .notAList: String(localized: "The address returned a web page or an error, not a filter list.")
            case .compileFailed: String(localized: "The filter lists didn't compile.")
            case .tooLarge: String(localized: "More than 150,000 rules, the most Safari's blocking engine can take.")
            }
        }
    }
}

/// Collects a download in the chunks it arrives in, cancelling it past the limit. Async bytes, checked one
/// at a time, took 15 s for EasyList instead of 0.1 s.
private final class LimitedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Used only on the session's serial delegate queue, after the continuation is set.
    var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
    private let limit: Int
    private var data = Data()
    private var response: URLResponse?
    private var overLimit = false

    init(limit: Int) { self.limit = limit }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        overLimit = response.expectedContentLength > limit
        completionHandler(overLimit ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        self.data.append(data)
        if self.data.count > limit {
            overLimit = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if overLimit {
            continuation?.resume(throwing: ContentBlocker.BlockerError.tooBig)
        } else if let error {
            continuation?.resume(throwing: error)
        } else if let response {
            continuation?.resume(returning: (data, response))
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
        continuation = nil
    }
}
