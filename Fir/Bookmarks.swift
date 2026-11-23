import Foundation
import MozillaAppServices

/// A saved page; `id` is its Places guid.
struct Bookmark: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let title: String
}

/// A bookmark folder with what is in it, filed as in Zen and Firefox.
struct BookmarkFolder: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let bookmarks: [Bookmark]
    let folders: [BookmarkFolder]

    var isEmpty: Bool { bookmarks.isEmpty && folders.allSatisfy(\.isEmpty) }
    var all: [Bookmark] { bookmarks + folders.flatMap(\.all) }
}

/// The bookmarks in Places, shared with Zen by the Sync "bookmarks" engine. Held whole in memory: menus,
/// the start page and search need them at once.
@Observable @MainActor
final class Bookmarks {
    static let shared = Bookmarks()

    /// Mobile, Toolbar, Menu and Other, in that order.
    private(set) var folders: [BookmarkFolder] = []
    private var all: [Bookmark] = []
    private var guids: [URL: [String]] = [:]
    /// Reads can finish out of order; only the latest one is kept.
    private var generation = 0

    /// The Mobile folder's own bookmarks, where Fir adds them; the start page shows these.
    var favorites: [Bookmark] { folders.first { $0.id == BookmarkRoots.MobileFolderGUID }?.bookmarks ?? [] }

    func folder(_ id: String) -> BookmarkFolder? {
        func find(in list: [BookmarkFolder]) -> BookmarkFolder? {
            for folder in list {
                if folder.id == id { return folder }
                if let found = find(in: folder.folders) { return found }
            }
            return nil
        }
        return find(in: folders)
    }

    func contains(_ url: URL?) -> Bool {
        url.map { guids[$0] != nil } ?? false
    }

    /// Title or address matches, for the search sheet.
    func matches(_ text: String, limit: Int = 4) -> [Bookmark] {
        Array(all.lazy.filter {
            $0.title.localizedCaseInsensitiveContains(text) || $0.url.absoluteString.localizedCaseInsensitiveContains(text)
        }.prefix(limit))
    }

    func reload() async {
        generation += 1
        let current = generation
        let tree = await Task.detached(priority: .userInitiated) {
            HistoryStore.shared?.bookmarkTree().map { $0.map(Self.folder) }
        }.value
        // A locked phone leaves the last good copy in place.
        guard let tree, current == generation else { return }
        folders = tree
        all = tree.flatMap(\.all)
        guids = Dictionary(grouping: all, by: \.url).mapValues { $0.map(\.id) }
    }

    /// After sign-out, even if Places can't be read to confirm the wipe.
    func clear() {
        generation += 1
        (folders, all, guids) = ([], [], [:])
    }

    func add(_ url: URL, title: String) async {
        guard Self.isOpenable(url), !contains(url) else { return }
        await Task.detached(priority: .userInitiated) { HistoryStore.shared?.addBookmark(url, title: title) }.value
        await reload()
    }

    /// Every bookmark of this address, in whichever folder.
    func remove(_ url: URL) async {
        await delete(guids[url] ?? [])
    }

    func delete(_ guids: [String]) async {
        guard !guids.isEmpty else { return }
        await Task.detached(priority: .userInitiated) {
            for guid in guids { HistoryStore.shared?.deleteBookmark(guid) }
        }.value
        await reload()
    }

    /// Web pages only: synced bookmarks can hold javascript: bookmarklets and place: queries.
    nonisolated static func isOpenable(_ url: URL) -> Bool {
        url.scheme == "https" || url.scheme == "http"
    }

    nonisolated private static func folder(_ data: BookmarkFolderData) -> BookmarkFolder {
        var bookmarks: [Bookmark] = []
        var folders: [BookmarkFolder] = []
        for child in data.children ?? [] {
            if let item = child as? BookmarkItemData, let url = URL(string: item.url), isOpenable(url) {
                bookmarks.append(Bookmark(id: item.guid, url: url, title: item.title))
            } else if let sub = child as? BookmarkFolderData {
                folders.append(folder(sub))
            }
        }
        return BookmarkFolder(id: data.guid, title: rootTitle(data.guid) ?? data.title, bookmarks: bookmarks, folders: folders)
    }

    /// Places stores the top folders' names in English; these are Firefox's own, translated.
    nonisolated private static func rootTitle(_ guid: String) -> String? {
        switch guid {
        case BookmarkRoots.MobileFolderGUID: String(localized: "Mobile Bookmarks")
        case BookmarkRoots.ToolbarFolderGUID: String(localized: "Bookmarks Toolbar")
        case BookmarkRoots.MenuFolderGUID: String(localized: "Bookmarks Menu")
        case BookmarkRoots.UnfiledFolderGUID: String(localized: "Other Bookmarks")
        default: nil
        }
    }
}
