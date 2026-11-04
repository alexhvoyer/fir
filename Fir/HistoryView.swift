import SwiftUI

/// Visited pages from this iPhone and, through Sync, from Zen; grouped by day, newest first.
struct HistoryView: View {
    let onOpen: () -> Void
    @Environment(BrowserModel.self) private var browser
    @Environment(AccountService.self) private var account
    @State private var entries: [HistoryStore.Entry] = []
    @State private var query = ""
    @State private var confirmClear = false

    var body: some View {
        List {
            ForEach(days, id: \.day) { group in
                Section(Self.title(for: group.day)) {
                    ForEach(group.entries) { entry in
                        Button { open(entry) } label: { row(entry) }
                            .foregroundStyle(.primary)
                            .swipeActions {
                                Button("Delete", role: .destructive) { delete(entry) }
                            }
                    }
                }
            }
        }
        .overlay {
            if entries.isEmpty { ContentUnavailableView("No History", systemImage: "clock") }
        }
        .searchable(text: $query)
        .navigationTitle("History")
        .toolbar {
            Button("Clear", role: .destructive) { confirmClear = true }.disabled(entries.isEmpty)
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { clear() }
        } message: {
            Text(account.isSignedIn ? "With history sync on, this can also clear it in Zen." : "")
        }
        // Reloads after a sync, which may bring in Zen's visits.
        .task(id: account.lastSynced) { await reload() }
        .task(id: query) { await reload() }
    }

    private var days: [(day: Date, entries: [HistoryStore.Entry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date ?? .distantPast) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    private static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func row(_ entry: HistoryStore.Entry) -> some View {
        HStack(spacing: 12) {
            SiteIcon(host: entry.url.host(), size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? entry.url.absoluteString : entry.title).lineLimit(1)
                Text(entry.url.host() ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if entry.isRemote {
                Image(systemName: "laptopcomputer").font(.caption).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
    }

    private func reload() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        entries = await Task.detached(priority: .userInitiated) {
            // Search result pages differ only in tracking parameters; one row per title and site is enough.
            var seen = Set<String>()
            let recent = (HistoryStore.shared?.recent() ?? []).filter {
                $0.title.isEmpty || seen.insert("\($0.url.host() ?? "")|\($0.title)").inserted
            }
            guard !text.isEmpty else { return recent }
            return recent.filter {
                $0.title.localizedCaseInsensitiveContains(text) || $0.url.absoluteString.localizedCaseInsensitiveContains(text)
            }
        }.value
    }

    private func open(_ entry: HistoryStore.Entry) {
        browser.open(entry.url)
        onOpen()
    }

    private func delete(_ entry: HistoryStore.Entry) {
        entries.removeAll { $0.url == entry.url }
        Task.detached(priority: .utility) { HistoryStore.shared?.delete(entry.url) }
    }

    private func clear() {
        entries = []
        Task.detached(priority: .utility) { HistoryStore.shared?.deleteAll() }
    }
}
