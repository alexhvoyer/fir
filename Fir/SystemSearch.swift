import AppIntents
import Foundation

/// A query the system hands over, from Spotlight or an intent, searched with the user's engine.
/// One that launched the app waits until a handler is set.
enum SystemSearch {
    @MainActor static var handler: ((URL) -> Void)? {
        didSet { deliver() }
    }
    @MainActor private static var pending: URL?

    /// Always a search, never an address: this text comes from outside the app.
    @MainActor static func perform(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let engine = UserDefaults.standard.string(forKey: SettingsKey.searchEngine).flatMap(SearchEngine.init(rawValue:))
        pending = (engine ?? .duckDuckGo).url(for: text)
        deliver()
    }

    @MainActor private static func deliver() {
        guard let handler, let url = pending else { return }
        pending = nil
        handler(url)
    }
}

/// The schema browsers declare for a web search; iOS 27 replaces it with `SearchInFirIntent`.
@AppIntent(schema: .browser.search)
struct SearchWebIntent: ShowInAppSearchResultsIntent {
    static var searchScopes: [StringSearchScope] = [.general]

    @Parameter var criteria: StringSearchCriteria

    @MainActor func perform() async throws -> some IntentResult {
        SystemSearch.perform(criteria.term)
        return .result()
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .system.searchInApp)
struct SearchInFirIntent: ShowInAppSearchResultsIntent {
    static var searchScopes: [StringSearchScope] = [.general]

    @Parameter var criteria: StringSearchCriteria

    @MainActor func perform() async throws -> some IntentResult {
        SystemSearch.perform(criteria.term)
        return .result()
    }
}
