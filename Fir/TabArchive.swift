import SwiftUI

/// How long a tab may go unviewed before Fir archives or clears it.
enum TabLifetime: Int, CaseIterable, Identifiable {
    case never = 0
    case halfDay = 43_200
    case day = 86_400
    case threeDays = 259_200
    case week = 604_800
    case twoWeeks = 1_209_600
    case month = 2_592_000

    var id: Self { self }
    var interval: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) }

    var name: String {
        switch self {
        case .never: "Never"
        case .halfDay: "12 Hours"
        case .day: "1 Day"
        case .threeDays: "3 Days"
        case .week: "1 Week"
        case .twoWeeks: "2 Weeks"
        case .month: "1 Month"
        }
    }

    static var archive: TabLifetime {
        TabLifetime(rawValue: UserDefaults.standard.object(forKey: SettingsKey.archiveTabsAfter) as? Int
                    ?? TabLifetime.week.rawValue) ?? .week
    }

    static var clear: TabLifetime {
        TabLifetime(rawValue: UserDefaults.standard.integer(forKey: SettingsKey.clearTabsAfter)) ?? .never
    }

    /// Clearing must come after archiving, or a tab would be cleared before it ever reached the archive.
    static func clearOptions(after archive: TabLifetime) -> [TabLifetime] {
        guard archive != .never else { return allCases }
        return allCases.filter { $0 == .never || $0.rawValue > archive.rawValue }
    }
}

/// A tab moved out of the deck after going unviewed, kept to be reopened.
struct ArchivedTab: Codable, Identifiable {
    var id = UUID()
    let url: URL
    let title: String
    let spaceID: String?
    let lastViewed: Date
}

/// Archived tabs as a JSON file; there can be hundreds, too many for UserDefaults.
enum ArchiveStore {
    private static var url: URL { URL.applicationSupportDirectory.appending(path: "archived-tabs.json") }

    /// Throws when the file is there but unreadable, as at a launch while the phone is locked.
    static func load() throws -> [ArchivedTab] {
        let data: Data
        do { data = try Data(contentsOf: url) } catch CocoaError.fileReadNoSuchFile { return [] }
        return (try? JSONDecoder().decode([ArchivedTab].self, from: data)) ?? []
    }

    static func save(_ tabs: [ArchivedTab]) {
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(tabs).write(to: url, options: .atomic)
    }
}

/// Settings > Tabs: when unused tabs are archived and cleared, and the archive itself.
struct TabsSettingsView: View {
    let onOpen: () -> Void
    @Environment(BrowserModel.self) private var browser
    @AppStorage(SettingsKey.archiveTabsAfter) private var archive = TabLifetime.week
    @AppStorage(SettingsKey.clearTabsAfter) private var clear = TabLifetime.never

    var body: some View {
        List {
            Section {
                Picker("Archive Tabs After", selection: $archive) {
                    ForEach(TabLifetime.allCases) { Text($0.name).tag($0) }
                }
            } footer: {
                Text("Tabs you haven't viewed in this long move to the archive, where you can reopen them. Private tabs close instead.")
            }
            Section {
                Picker("Clear Tabs After", selection: $clear) {
                    ForEach(TabLifetime.clearOptions(after: archive)) { Text($0.name).tag($0) }
                }
            } footer: {
                Text(archive == .never
                     ? "Tabs you haven't viewed in this long close. They stay in Recently Closed."
                     : "Archived tabs you haven't viewed in this long are deleted. It's always longer than archiving.")
            }
            Section {
                NavigationLink {
                    ArchivedTabsView(onOpen: onOpen)
                } label: {
                    LabeledContent("Archived Tabs", value: browser.archived.count.formatted())
                }
            }
        }
        .navigationTitle("Tabs")
        .onChange(of: archive) {
            if !TabLifetime.clearOptions(after: archive).contains(clear) {
                clear = TabLifetime.clearOptions(after: archive).first { $0 != .never } ?? .never
            }
            browser.sweepIdleTabs()
        }
        .onChange(of: clear) { browser.sweepIdleTabs() }
    }
}

private struct ArchivedTabsView: View {
    let onOpen: () -> Void
    @Environment(BrowserModel.self) private var browser
    @State private var query = ""
    @State private var confirmClear = false

    private var shown: [ArchivedTab] {
        let text = query.trimmingCharacters(in: .whitespaces)
        let all = browser.archived.sorted { $0.lastViewed > $1.lastViewed }
        guard !text.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(text) || $0.url.absoluteString.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        List {
            ForEach(shown) { tab in
                Button {
                    browser.reopen(tab)
                    onOpen()
                } label: {
                    HStack(spacing: 12) {
                        SiteIcon(host: tab.url.host(), size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tab.title.isEmpty ? tab.url.absoluteString : tab.title).lineLimit(1)
                            Text(tab.url.host() ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(tab.lastViewed, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                .swipeActions {
                    Button("Delete", role: .destructive) { browser.deleteArchived([tab.id]) }
                }
            }
        }
        .overlay {
            if browser.archived.isEmpty { ContentUnavailableView("No Archived Tabs", systemImage: "archivebox") }
        }
        .searchable(text: $query)
        .navigationTitle("Archived Tabs")
        .toolbar {
            Button("Clear", role: .destructive) { confirmClear = true }.disabled(browser.archived.isEmpty)
        }
        .confirmationDialog("Delete all archived tabs?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { browser.deleteArchived(browser.archived.map(\.id)) }
        }
    }
}
