import Foundation
import MozillaAppServices

/// Browsing history in Mozilla's Places database; the Sync "history" engine shares it with Zen.
/// Calls block on SQLite, so callers stay off the main actor.
final class HistoryStore: @unchecked Sendable {
    static let shared = try? HistoryStore()

    private let api: PlacesAPI

    private init() throws {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        api = try PlacesAPI(path: dir.appendingPathComponent("places.db").path)
        api.registerWithSyncManager()
    }

    func recordVisit(_ url: URL, title: String?) {
        guard url.scheme == "https" || url.scheme == "http" else { return }
        try? api.getWriter().applyObservation(visitObservation: VisitObservation(
            url: url.absoluteString,
            title: title?.isEmpty == false ? title : nil,
            visitType: .link,
            at: Self.now
        ))
    }

    /// Most recent first, one row per page: Places keeps every visit, the list wants pages.
    func recent(limit: Int = 300) -> [Entry] {
        let infos = (try? api.openReader().getVisitPageWithBound(
            bound: Self.now, offset: 0, count: Int64(limit * 3), excludedTypes: 0
        ).infos) ?? []
        var seen = Set<String>()
        return infos
            .filter { Self.shownTypes.contains($0.visitType) && !$0.isHidden && seen.insert($0.url).inserted }
            .prefix(limit)
            .compactMap(Entry.init)
    }

    /// Matches by title and address, ranked by how often and recently a page was visited.
    func search(_ text: String, limit: Int = 6) -> [Entry] {
        let results = (try? api.openReader().queryAutocomplete(search: text, limit: Int32(limit))) ?? []
        return results.compactMap { result in
            URL(string: result.url).map { Entry(url: $0, title: result.title, date: nil, isRemote: false) }
        }
    }

    /// Most visited sites, weighted by how recently; for the start page when there are no Zen pins.
    func topSites(limit: Int = 8) -> [Entry] {
        let infos = (try? api.openReader().getTopFrecentSiteInfos(numItems: Int32(limit), thresholdOption: .skipOneTimePages)) ?? []
        return infos.compactMap { info in
            URL(string: info.url).map { Entry(url: $0, title: info.title ?? "", date: nil, isRemote: false) }
        }
    }

    /// A completed address: written the way people type it ("dtf.ru"), the page, and its title.
    struct Completion: Equatable {
        let text: String
        let url: URL
        /// The title of exactly that page, if it was visited; never another page's on the site.
        let title: String?
    }

    /// Places' own URL autofill, as in Firefox: the most frecent visited site starting with `text`, or nil.
    func autofill(_ text: String) -> Completion? {
        guard !text.isEmpty, !text.contains(" "),
              let match = try? api.openReader().matchUrl(query: text), let url = URL(string: match) else { return nil }
        var shown = match
        for prefix in ["https://", "http://", "www."] where shown.hasPrefix(prefix) {
            shown.removeFirst(prefix.count)
        }
        if shown.hasSuffix("/") { shown.removeLast() }
        guard shown.lowercased().hasPrefix(text.lowercased()) else { return nil }
        // From the visits: the autocomplete result stands the address in for a missing title.
        let visits = (try? api.openReader().getVisitPageWithBound(
            bound: Self.now, offset: 0, count: 1000, excludedTypes: 0
        ).infos) ?? []
        let title = visits.first { $0.url == match && !($0.title ?? "").isEmpty }?.title
        return Completion(text: shown, url: url, title: title)
    }

    func delete(_ url: URL) {
        try? api.getWriter().deleteVisitsFor(url: url.absoluteString)
    }

    func deleteAll() {
        try? api.getWriter().deleteEverythingHistory()
    }

    struct Entry: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let title: String
        let date: Date?
        /// Visited on another synced device, such as Zen on the Mac.
        let isRemote: Bool

        init(url: URL, title: String, date: Date?, isRemote: Bool) {
            self.url = url
            self.title = title
            self.date = date
            self.isRemote = isRemote
        }

        init?(_ info: HistoryVisitInfo) {
            guard let url = URL(string: info.url) else { return nil }
            self.init(url: url, title: info.title ?? "", date: Date(timeIntervalSince1970: Double(info.timestamp) / 1000),
                      isRemote: info.isRemote)
        }
    }

    private static let shownTypes: Set<VisitType> = [.link, .typed, .bookmark, .reload]

    private static var now: PlacesTimestamp { PlacesTimestamp(Date.now.timeIntervalSince1970 * 1000) }
}
