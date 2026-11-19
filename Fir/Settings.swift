import SwiftUI

enum SearchEngine: String, CaseIterable, Identifiable {
    case duckDuckGo, google, bing, startpage, kagi, custom

    var id: Self { self }

    /// The engines offered without typing an address.
    static let presets = allCases.filter { $0 != .custom }

    var name: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .google: "Google"
        case .bing: "Bing"
        case .startpage: "Startpage"
        case .kagi: "Kagi"
        case .custom: Self.customSite?.title ?? String(localized: "Custom")
        }
    }

    func url(for query: String) -> URL? {
        let base: String
        switch self {
        case .duckDuckGo: base = "https://duckduckgo.com/"
        case .google: base = "https://www.google.com/search"
        case .bing: base = "https://www.bing.com/search"
        case .startpage: base = "https://www.startpage.com/do/search"
        case .kagi: base = "https://kagi.com/search"
        case .custom:
            // An address that doesn't work yet still searches, rather than leaving Return doing nothing.
            return Self.url(fromTemplate: Self.customSite?.template ?? "", query: query) ?? Self.duckDuckGo.url(for: query)
        }
        var components = URLComponents(string: base)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }

    /// The engine from the list chosen as the default, when it isn't one of the cases above.
    static var customSite: SearchSite? {
        let id = UserDefaults.standard.string(forKey: SettingsKey.customSearchID) ?? SearchSites.legacyID
        return SearchSites.saved.site(id)
    }

    /// Nil unless the template is a web address with `%s` in it.
    static func url(fromTemplate template: String, query: String) -> URL? {
        let template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        // The query never picks the site: in the host, Spotlight's text would open as an address.
        guard template.contains("%s"),
              let probe = URL(string: template.replacingOccurrences(of: "%s", with: "firquery")),
              probe.host()?.lowercased().contains("firquery") == false
        else { return nil }
        // Encoded so the query stays one value: its own & or # would end it. ASCII only: .alphanumerics
        // also passes Cyrillic and other letters through raw.
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved)
        guard let encoded, let url = URL(string: template.replacingOccurrences(of: "%s", with: encoded)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil
        else { return nil }
        return url
    }

    /// OpenSearch suggestions endpoint, answering `[query, [suggestion, ...]]`.
    /// Startpage's endpoint returns no content, and a custom engine names none.
    func suggestionsURL(for query: String) -> URL? {
        let (base, param, extra): (String, String, [URLQueryItem]) = switch self {
        case .duckDuckGo: ("https://duckduckgo.com/ac/", "q", [URLQueryItem(name: "type", value: "list")])
        case .google: ("https://suggestqueries.google.com/complete/search", "q", [URLQueryItem(name: "client", value: "firefox")])
        case .bing: ("https://api.bing.com/osjson.aspx", "query", [])
        case .kagi: ("https://kagi.com/api/autosuggest", "q", [])
        case .startpage, .custom: ("", "", [])
        }
        guard var components = URLComponents(string: base), !base.isEmpty else { return nil }
        components.queryItems = [URLQueryItem(name: param, value: query)] + extra
        return components.url
    }

    /// What's typed leaves no cache on disk, and no cookie ties private queries to regular ones.
    private static let suggestionSession = URLSession(configuration: .ephemeral)

    func suggestions(for query: String) async -> [String] {
        guard let url = suggestionsURL(for: query),
              let (data, _) = try? await Self.suggestionSession.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count > 1, let list = json[1] as? [String],
              // The response echoes its query; a late answer to an earlier prefix is dropped.
              (json[0] as? String)?.lowercased() == query.lowercased()
        else { return [] }
        return list
    }
}

/// An engine in Settings > Search, built in or added, with the keyword that picks it in the address bar.
struct SearchSite: Codable, Identifiable, Hashable {
    /// A built-in engine's own id, such as a `SearchEngine` raw value, or a UUID for one the user added.
    var id: String
    var name: String
    /// The search address, `%s` standing for the query, as in Firefox and Zen.
    var template: String
    var keyword: String
    var quickSearch: Bool

    var isBuiltIn: Bool { SearchSites.builtIn.contains { $0.id == id } }
    var isValid: Bool { SearchEngine.url(fromTemplate: template, query: "fir") != nil }
    var title: String { name.isEmpty ? String(localized: "Untitled") : name }
    var host: String? { URL(string: template.replacingOccurrences(of: "%s", with: "fir"))?.host() }
    /// What the bar compares against; a stray space typed with the keyword shouldn't turn it off.
    var trigger: String? {
        let word = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        return quickSearch && !word.isEmpty ? word : nil
    }
}

/// Every engine in Settings > Search, kept as JSON in the settings.
struct SearchSites: RawRepresentable, Equatable {
    var list: [SearchSite]

    init(list: [SearchSite]) { self.list = list }

    /// Built-in engines take name and address from the code, so fixes and the system language reach saved
    /// lists; ones added in a later version join.
    init?(rawValue: String) {
        guard let saved = try? JSONDecoder().decode([SearchSite].self, from: Data(rawValue.utf8)) else { return nil }
        list = saved.map { site in
            guard let current = Self.builtIn.first(where: { $0.id == site.id }) else { return site }
            return SearchSite(id: site.id, name: current.name, template: current.template, keyword: site.keyword,
                              quickSearch: site.quickSearch)
        } + Self.builtIn.filter { site in !saved.contains { $0.id == site.id } }
    }

    var rawValue: String {
        (try? String(data: JSONEncoder().encode(list), encoding: .utf8)) ?? "[]"
    }

    func site(_ id: String) -> SearchSite? { list.first { $0.id == id } }

    /// "wiki fir" searches "fir" with the engine whose keyword is "wiki".
    func quickSearch(_ input: String) -> (site: SearchSite, query: String)? {
        guard let (site, rest) = keyword(in: input) else { return nil }
        let query = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : (site, query)
    }

    /// The engine whose keyword starts the text and is followed by a space, and the text after that space.
    func keyword(in input: String) -> (site: SearchSite, rest: String)? {
        let text = input.drop { $0.isWhitespace }
        guard let space = text.firstIndex(where: \.isWhitespace),
              let site = list.first(where: { $0.trigger == text[..<space].lowercased() && $0.isValid })
        else { return nil }
        return (site, String(text[space...].drop { $0.isWhitespace }))
    }

    static var saved: SearchSites {
        UserDefaults.standard.string(forKey: SettingsKey.searchSites).flatMap(SearchSites.init(rawValue:)) ?? initial
    }

    /// The id the single custom address had before the list.
    static let legacyID = "custom"

    /// The built-in list, plus the custom address saved before the list existed.
    static var initial: SearchSites {
        let legacy = UserDefaults.standard.string(forKey: SettingsKey.customSearchURL) ?? ""
        guard !legacy.isEmpty else { return SearchSites(list: builtIn) }
        let custom = SearchSite(id: legacyID, name: String(localized: "Custom"), template: legacy, keyword: "", quickSearch: false)
        return SearchSites(list: builtIn + [custom])
    }

    /// The usual browser searches have keywords on; YouTube is mostly searched in its app, so it starts off.
    static let builtIn: [SearchSite] = {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return [
            SearchSite(id: SearchEngine.duckDuckGo.rawValue, name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s",
                       keyword: "d", quickSearch: true),
            SearchSite(id: SearchEngine.google.rawValue, name: "Google", template: "https://www.google.com/search?q=%s",
                       keyword: "g", quickSearch: true),
            SearchSite(id: SearchEngine.bing.rawValue, name: "Bing", template: "https://www.bing.com/search?q=%s",
                       keyword: "b", quickSearch: true),
            SearchSite(id: SearchEngine.startpage.rawValue, name: "Startpage",
                       template: "https://www.startpage.com/do/search?q=%s", keyword: "sp", quickSearch: false),
            SearchSite(id: SearchEngine.kagi.rawValue, name: "Kagi", template: "https://kagi.com/search?q=%s",
                       keyword: "k", quickSearch: false),
            SearchSite(id: "wikipedia", name: "Wikipedia", template: "https://\(language).wikipedia.org/w/index.php?search=%s",
                       keyword: "wiki", quickSearch: true),
            SearchSite(id: "youtube", name: "YouTube", template: "https://www.youtube.com/results?search_query=%s",
                       keyword: "yt", quickSearch: false),
        ]
    }()
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var name: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    private var style: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// Restyles every window, sheets and alerts included, at once.
    @MainActor static func apply(_ appearance: Appearance) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = appearance.style }
        }
    }
}

/// The tint for links, controls and selection. System blue unless the user picks another.
enum Accent: String, CaseIterable, Identifiable {
    case system, pine, purple, pink, green, teal

    var id: Self { self }

    var name: String {
        switch self {
        // Its own key: Russian, for one, inflects it differently from the theme's "System".
        case .system: String(localized: "Accent.System", defaultValue: "System")
        case .pine: String(localized: "Pine")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .green: String(localized: "Green")
        case .teal: String(localized: "Teal")
        }
    }

    /// nil keeps the system's own accent.
    var color: Color? {
        switch self {
        case .system: nil
        case .pine: Palette.pine
        case .purple: .purple
        case .pink: .pink
        case .green: .green
        case .teal: .teal
        }
    }
}

/// UserDefaults keys shared by @AppStorage call sites.
/// What a new tab shows: search in a sheet over the deck, or a tab of its own with the start page.
enum NewTabStyle: String, CaseIterable, Identifiable {
    case sheet, page

    var id: Self { self }

    var name: String {
        switch self {
        case .sheet: String(localized: "Search Sheet")
        case .page: String(localized: "Start Page")
        }
    }
}

/// What the bar's tabs button does in portrait, where no separate + sits beside it.
enum CornerButton: String, CaseIterable, Identifiable {
    case tabs, newTab

    var id: Self { self }

    var name: String {
        switch self {
        case .tabs: String(localized: "Show Tabs")
        case .newTab: String(localized: "New Tab")
        }
    }
}

/// How the tab overview lays out a workspace's tabs.
enum TabLayout: String, CaseIterable, Identifiable {
    case deck, grid

    var id: Self { self }

    var name: String {
        switch self {
        case .deck: String(localized: "Cards")
        case .grid: String(localized: "Grid")
        }
    }
}

/// A button the address bar can show right of the address, in the order the user put them.
enum BarAction: String, CaseIterable, Identifiable {
    case share, reload, find, translate

    var id: Self { self }

    static let defaults: [BarAction] = [.share, .reload]
    /// More squeezed the address down to a few letters.
    static let limit = 3

    var name: String {
        switch self {
        case .share: String(localized: "Share")
        case .reload: String(localized: "Reload")
        case .find: String(localized: "Find on Page")
        case .translate: String(localized: "Translate")
        }
    }

    var symbol: String {
        switch self {
        case .share: "square.and.arrow.up"
        case .reload: "arrow.clockwise"
        case .find: "text.magnifyingglass"
        case .translate: "translate"
        }
    }

    /// Stored as comma-separated names; ones this version doesn't know are dropped.
    static func decode(_ stored: String) -> [BarAction] {
        stored.split(separator: ",").compactMap { BarAction(rawValue: String($0)) }
    }

    static func encode(_ actions: [BarAction]) -> String {
        actions.map(\.rawValue).joined(separator: ",")
    }
}

enum SettingsKey {
    static let searchEngine = "searchEngine"
    /// The single custom address before the engine list; read once to move it into the list.
    static let customSearchURL = "customSearchURL"
    static let customSearchID = "customSearchID"
    static let searchSites = "searchSites"
    static let appearance = "appearance"
    static let accent = "accent"
    static let collapseOnScroll = "collapseOnScroll"
    static let searchSuggestions = "searchSuggestions"
    static let historySuggestions = "historySuggestions"
    static let blockAds = "blockAds"
    static let lockApp = "lockApp"
    static let lockPrivateTabs = "lockPrivateTabs"
    static let httpsOnly = "httpsOnly"
    static let globalPrivacyControl = "globalPrivacyControl"
    static let hardenPrivateTabs = "hardenPrivateTabs"
    static let haptics = "haptics"
    static let keyboardAtLaunch = "keyboardAtLaunch"
    static let fullWidthPages = "fullWidthPages"
    static let swipeAnywhere = "swipeAnywhere"
    static let newTabStyle = "newTabStyle"
    static let tabLayout = "tabLayout"
    static let cornerButton = "cornerButton"
    static let rememberHistory = "rememberHistory"
    static let barActions = "barActions"
    static let translateTarget = "translateTarget"
    static let intelligenceSearch = "intelligenceSearch"
    static let archiveTabsAfter = "archiveTabsAfter"
    static let clearTabsAfter = "clearTabsAfter"
    static let onboardingDone = "onboardingDone"
    static let whatsNew = "whatsNew"
    static let whatsNewSeen = "whatsNewSeen"
    static let syncTabs = "syncTabs"
    static let syncHistory = "syncHistory"
    static let syncWorkspaces = "syncWorkspaces"
    static let syncPasswords = "syncPasswords"
    static let offerPasswords = "offerPasswords"
    static let hiddenDevices = "hiddenDevices"
    static let signInCardHidden = "signInCardHidden"
    static let isDefaultBrowser = "isDefaultBrowser"
    static let defaultBrowserRetry = "defaultBrowserRetry"
}

/// Whether Fir is the default browser. iOS answers about four times a year and throws in between, so the
/// last answer is kept and iOS isn't asked again before the date it gives.
enum DefaultBrowser {
    @MainActor static func check() -> Bool? {
        let defaults = UserDefaults.standard
        let known = defaults.object(forKey: SettingsKey.isDefaultBrowser) as? Bool
        if let retry = defaults.object(forKey: SettingsKey.defaultBrowserRetry) as? Date, retry > .now { return known }
        do {
            let answer = try UIApplication.shared.isDefault(.webBrowser)
            defaults.set(answer, forKey: SettingsKey.isDefaultBrowser)
            return answer
        } catch {
            let retry = (error as NSError).userInfo[UIApplication.CategoryDefaultError.retryAvailableDateErrorKey] as? Date
            defaults.set(retry, forKey: SettingsKey.defaultBrowserRetry)
            return known
        }
    }

    /// Other apps hand web links only to the default browser.
    static func linkArrived() {
        UserDefaults.standard.set(true, forKey: SettingsKey.isDefaultBrowser)
    }
}

extension UserDefaults {
    /// For toggles that default to on: `bool(forKey:)` reads an unset key as false.
    func bool(forKey key: String, default value: Bool) -> Bool {
        object(forKey: key) as? Bool ?? value
    }
}

extension View {
    /// The system's sensory feedback, unless Haptics is off in Settings.
    func haptic<T: Equatable>(_ feedback: SensoryFeedback, trigger: T,
                              when condition: @escaping (T, T) -> Bool = { _, _ in true }) -> some View {
        sensoryFeedback(trigger: trigger) { old, new in
            UserDefaults.standard.bool(forKey: SettingsKey.haptics, default: true) && condition(old, new) ? feedback : nil
        }
    }
}
