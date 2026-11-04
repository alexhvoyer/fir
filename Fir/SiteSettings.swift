import SwiftUI
import WebKit

/// Choices kept per site (by host, without "www."), set from the page sheet.
@MainActor
@Observable
final class SiteSettings {
    static let shared = SiteSettings()

    struct Entry: Codable, Equatable {
        var blockAds = true
        var reader = false
        var desktop = false
        var zoom = 1.0
    }

    private(set) var entries: [String: Entry] = {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }()

    private static let key = "siteSettings"

    static func site(_ url: URL?) -> String? {
        guard let host = url?.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func entry(for url: URL?) -> Entry {
        Self.site(url).flatMap { entries[$0] } ?? Entry()
    }

    func update(_ url: URL?, _ change: (inout Entry) -> Void) {
        guard let site = Self.site(url) else { return }
        var entry = entries[site] ?? Entry()
        change(&entry)
        entries[site] = entry == Entry() ? nil : entry
        save()
    }

    /// Drops the site's cookies, storage and caches, and its settings here.
    func forget(_ url: URL?) async {
        guard let site = Self.site(url) else { return }
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let matching = records.filter { site == $0.displayName || site.hasSuffix("." + $0.displayName) }
        await store.removeData(ofTypes: types, for: matching)
        entries[site] = nil
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }
}
