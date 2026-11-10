import AppIntents
import Foundation

/// A query the system hands over, from Spotlight or an intent, searched with the user's engine.
enum SystemSearch {
    @MainActor static let requests = PendingRequest<URL>()

    /// Always a search, never an address: this text comes from outside the app.
    @MainActor static func perform(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let engine = UserDefaults.standard.string(forKey: SettingsKey.searchEngine).flatMap(SearchEngine.init(rawValue:))
        if let url = (engine ?? .duckDuckGo).url(for: text) { requests.send(url) }
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
