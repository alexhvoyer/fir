import SwiftUI

/// The bookmark folders as Zen files them; a search lists matches from all of them.
struct BookmarksView: View {
    /// A folder deeper in, looked up afresh so deletions show; nil lists the top folders.
    var folderID: String?
    let onOpen: (URL) -> Void
    @State private var query = ""
    private var bookmarks: Bookmarks { .shared }
    private var folder: BookmarkFolder? { folderID.flatMap(bookmarks.folder) }

    var body: some View {
        List {
            if !query.isEmpty {
                ForEach(bookmarks.matches(query, limit: 100)) { row($0) }
            } else if let folder {
                folders(folder.folders)
                ForEach(folder.bookmarks) { row($0) }
            } else {
                folders(bookmarks.folders.filter { !$0.isEmpty })
            }
        }
        .overlay {
            if folderID == nil, query.isEmpty, bookmarks.folders.allSatisfy(\.isEmpty) {
                ContentUnavailableView("No Bookmarks", systemImage: "bookmark",
                                       description: Text("Pages you bookmark, and those from Zen, show here."))
            }
        }
        .searchable(text: $query)
        .navigationTitle(folder?.title ?? String(localized: "Bookmarks"))
        .task { await bookmarks.reload() }
    }

    private func folders(_ list: [BookmarkFolder]) -> some View {
        ForEach(list) { sub in
            NavigationLink {
                BookmarksView(folderID: sub.id, onOpen: onOpen)
            } label: {
                Label(sub.title, systemImage: "folder")
            }
        }
    }

    private func row(_ bookmark: Bookmark) -> some View {
        Button {
            onOpen(bookmark.url)
        } label: {
            HStack(spacing: 12) {
                SiteIcon(host: bookmark.url.host(), size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bookmark.title.isEmpty ? bookmark.url.absoluteString : bookmark.title).lineLimit(1)
                    Text(bookmark.url.host() ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .foregroundStyle(.primary)
        .swipeActions {
            Button("Delete", role: .destructive) { Task { await bookmarks.delete([bookmark.id]) } }
        }
        .contextMenu {
            Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = bookmark.url }
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await bookmarks.delete([bookmark.id]) } }
        }
    }
}
