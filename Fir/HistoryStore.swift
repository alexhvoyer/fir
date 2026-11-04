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

    /// Places' own URL autofill, as in Firefox: the most frecent visited site starting with `text`,
    /// written the way people type it ("dtf.ru"), or nil.
    func autofill(_ text: String) -> String? {
        guard !text.isEmpty, !text.contains(" "),
              let url = try? api.openReader().matchUrl(query: text) else { return nil }
        var shown = url
        for prefix in ["https://", "http://", "www."] where shown.hasPrefix(prefix) {
            shown.removeFirst(prefix.count)
        }
        if shown.hasSuffix("/") { shown.removeLast() }
        return shown.lowercased().hasPrefix(text.lowercased()) ? shown : nil
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
