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

    func suggestions(for query: String) async -> [String] {
        guard let url = suggestionsURL(for: query),
              let (data, _) = try? await URLSession.shared.data(from: url),
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
    var name: String { rawValue.capitalized }

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
    var name: String { rawValue.capitalized }

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
        case .sheet: "Search Sheet"
        case .page: "Start Page"
        }
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
