import SwiftUI

enum SearchEngine: String, CaseIterable, Identifiable {
    case duckDuckGo, google, bing, startpage

    var id: Self { self }

    var name: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .google: "Google"
        case .bing: "Bing"
        case .startpage: "Startpage"
        }
    }

    func url(for query: String) -> URL? {
        let base = switch self {
        case .duckDuckGo: "https://duckduckgo.com/"
        case .google: "https://www.google.com/search"
        case .bing: "https://www.bing.com/search"
        case .startpage: "https://www.startpage.com/do/search"
        }
        var components = URLComponents(string: base)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }

    /// OpenSearch suggestions endpoint, answering `[query, [suggestion, ...]]`.
    /// Startpage's endpoint returns no content, so it gets none.
    func suggestionsURL(for query: String) -> URL? {
        let (base, param, extra): (String, String, [URLQueryItem]) = switch self {
        case .duckDuckGo: ("https://duckduckgo.com/ac/", "q", [URLQueryItem(name: "type", value: "list")])
        case .google: ("https://suggestqueries.google.com/complete/search", "q", [URLQueryItem(name: "client", value: "firefox")])
        case .bing: ("https://api.bing.com/osjson.aspx", "query", [])
        case .startpage: ("", "", [])
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
    static let swipeAnywhere = "swipeAnywhere"
    static let newTabStyle = "newTabStyle"
    static let tabLayout = "tabLayout"
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
    static let hiddenDevices = "hiddenDevices"
    static let signInCardHidden = "signInCardHidden"
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
