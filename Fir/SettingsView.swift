import SwiftUI
import WebKit

struct SettingsView: View {
    /// Shows a page opened from settings (history) once the sheet is gone.
    var onOpenPage: () -> Void = {}
    /// Asks for onboarding once this sheet has gone: nothing else can be presented over it from the root.
    var onShowOnboarding: () -> Void = {}
    @Environment(AccountService.self) private var account
    @Environment(\.dismiss) private var dismiss
    /// Starts on Workspaces when opened from the deck's settings button; Back leads to the rest.
    @State private var path: [Page]
    @State private var showWhatsNew = false

    enum Page: Hashable { case workspaces }

    init(onOpenPage: @escaping () -> Void = {}, onShowOnboarding: @escaping () -> Void = {}, opensWorkspaces: Bool = false) {
        self.onOpenPage = onOpenPage
        self.onShowOnboarding = onShowOnboarding
        _path = State(initialValue: opensWorkspaces ? [.workspaces] : [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    link("General", icon: "gearshape", color: .gray) { GeneralSettingsView() }
                    link("Search", icon: "magnifyingglass", color: .blue) { SearchSettingsView() }
                    link("Appearance", icon: "circle.lefthalf.filled", color: .indigo) { AppearanceSettingsView() }
                }
                Section {
                    link("Sync", icon: "arrow.triangle.2.circlepath", color: .orange,
                         detail: account.email ?? (account.isSignedIn ? "Signed in" : "Off")) { SyncSettingsView() }
                    if account.isSignedIn {
                        link("Workspaces", icon: "square.grid.2x2.fill", color: .mint,
                             detail: account.zenWorkspaces.map { "\($0.spaces.count)" }) { WorkspacesSettingsView() }
                    }
                    link("Tabs", icon: "square.on.square", color: .orange) {
                        TabsSettingsView { dismiss(); onOpenPage() }
                    }
                    link("History", icon: "clock", color: .teal) {
                        HistoryView { dismiss(); onOpenPage() }
                    }
                    link("Passwords", icon: "key.fill", color: .gray) { PasswordsView() }
                    link("Downloads", icon: "arrow.down.circle.fill", color: .blue) { DownloadsView() }
                }
                Section {
                    link("Privacy & Security", icon: "hand.raised.fill", color: .green) { PrivacySettingsView() }
                    link("Extensions", icon: "puzzlepiece.extension.fill", color: .purple) { ExtensionsSettingsView() }
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.shortVersion)
                    Button("What's New") { showWhatsNew = true }
                    Button("Show Onboarding") {
                        onShowOnboarding()
                        dismiss()
                    }
                    Text("Fir is an independent app, not affiliated with Zen or Mozilla. Sync uses Mozilla application-services (MPL-2.0).")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Page.self) { _ in WorkspacesSettingsView() }
            .sheet(isPresented: $showWhatsNew) { WhatsNewView() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }

    private func link(_ title: String, icon: String, color: Color, detail: String? = nil,
                      @ViewBuilder destination: () -> some View) -> some View {
        NavigationLink(destination: destination) {
            Label {
                LabeledContent(title, value: detail ?? "")
            } icon: {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(color.gradient, in: .rect(cornerRadius: 7))
            }
        }
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(SettingsKey.collapseOnScroll) private var collapseOnScroll = true
    @AppStorage(SettingsKey.haptics) private var haptics = true
    @AppStorage(SettingsKey.keyboardAtLaunch) private var keyboardAtLaunch = false
    @AppStorage(SettingsKey.swipeAnywhere) private var swipeAnywhere = false
    @AppStorage(SettingsKey.whatsNew) private var whatsNew = true
    @AppStorage(SettingsKey.newTabStyle) private var newTabStyle = NewTabStyle.sheet
    @State private var isDefault: Bool?

    var body: some View {
        List {
            Section {
                LabeledContent("Default Browser", value: isDefault == true ? "Fir" : "Not Fir")
                Button("Open iOS Settings") {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
            } footer: {
                Text("iOS offers an app as the default browser only if Apple granted it the default-browser entitlement, which the developer requests for the app's bundle ID. This build doesn't have it yet.")
            }
            Section {
                Picker("New Tab", selection: $newTabStyle) {
                    ForEach(NewTabStyle.allCases) { Text($0.name).tag($0) }
                }
            } footer: {
                Text("Search Sheet opens search at once. Start Page shows your pinned and frequent sites and history, with search a tap on the address bar away.")
            }
            Section {
                Toggle("Collapse Toolbar on Scroll", isOn: $collapseOnScroll)
                Toggle("Haptics", isOn: $haptics)
            }
            Section {
                Toggle("Swipe Anywhere to Navigate", isOn: $swipeAnywhere)
            } header: {
                Text("Experimental")
            } footer: {
                Text("Swipe sideways anywhere on a page to go back or forward, not only from the edge. Some sites with sliders may react to it too.")
            }
            Section {
                Toggle("Open Search at Launch", isOn: $keyboardAtLaunch)
            } footer: {
                Text("Fir opens ready to type. The page you were reading stays behind the search.")
            }
            Section {
                Toggle("What's New After Updates", isOn: $whatsNew)
                    // Turning it back on waits for the next list, not one skipped while off.
                    .onChange(of: whatsNew) { WhatsNew.markSeen() }
            } footer: {
                Text("Fir shows a short list of changes after a major update. It stays in Settings under About.")
            }
        }
        .navigationTitle("General")
        .task {
            // Rate-limited by iOS; on an error the status just stays unknown.
            isDefault = try? UIApplication.shared.isDefault(.webBrowser)
        }
    }
}

private struct SearchSettingsView: View {
    @AppStorage(SettingsKey.searchEngine) private var engine = SearchEngine.duckDuckGo
    @AppStorage(SettingsKey.searchSuggestions) private var searchSuggestions = true
    @AppStorage(SettingsKey.historySuggestions) private var historySuggestions = true
    @AppStorage(SettingsKey.intelligenceSearch) private var intelligenceSearch = true

    var body: some View {
        List {
            Section("Search Engine") {
                Picker("Search Engine", selection: $engine) {
                    ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                Toggle("Search Engine Suggestions", isOn: $searchSuggestions)
                Toggle("Pages from History", isOn: $historySuggestions)
            } footer: {
                Text("Suggestions send what you type to the search engine. History matches stay on this device.")
            }
            if IntelligenceSearch.isSupported {
                Section {
                    Toggle("Intelligence Search", isOn: $intelligenceSearch)
                } footer: {
                    Text(IntelligenceSearch.isAvailable
                         ? "Offers to read a search's first results and write one answer with its sources, on this iPhone. Answers can get things wrong."
                         : "Turn on Apple Intelligence in iOS Settings to use it.")
                }
            }
        }
        .navigationTitle("Search")
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage(SettingsKey.appearance) private var appearance = Appearance.system
    @AppStorage(SettingsKey.accent) private var accent = Accent.system
    /// The alternate icon's name, nil for the default; iOS keeps it, this mirrors it for the list.
    @State private var icon = UIApplication.shared.alternateIconName

    private static let icons: [(name: String?, title: String, preview: String)] = [
        (nil, "Snow", "IconPreview-Default"),
        ("AppIcon-Night", "Night", "IconPreview-Night"),
        ("AppIcon-Spruce", "Spruce", "IconPreview-Spruce"),
    ]

    var body: some View {
        List {
            Picker("Theme", selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Accent Color", selection: $accent) {
                ForEach(Accent.allCases) { option in
                    Label {
                        Text(option.name)
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(option.color ?? .blue)
                    }
                    .tag(option)
                }
            }
            .pickerStyle(.inline)
            Section("App Icon") {
                ForEach(Self.icons, id: \.title) { option in
                    Button {
                        Task {
                            try? await UIApplication.shared.setAlternateIconName(option.name)
                            icon = UIApplication.shared.alternateIconName
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(option.preview)
                                .resizable()
                                .frame(width: 52, height: 52)
                                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(.primary.opacity(0.1)))
                            Text(option.title).foregroundStyle(.primary)
                            Spacer()
                            if icon == option.name { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    // The row's title, not a link: a plain button would tint it.
                    .foregroundStyle(.primary)
                }
            }
        }
        .navigationTitle("Appearance")
    }
}

/// Open tabs from other devices: the engine itself, then which devices' tabs show here.
private struct SyncSettingsView: View {
    @Environment(AccountService.self) private var account
    @AppStorage(SettingsKey.syncTabs) private var syncTabs = true
    @AppStorage(SettingsKey.syncHistory) private var syncHistory = true
    @AppStorage(SettingsKey.syncWorkspaces) private var syncWorkspaces = true
    @AppStorage(SettingsKey.syncPasswords) private var syncPasswords = true
    @State private var showSignIn = false

    var body: some View {
        List {
            if account.isSignedIn {
                Section {
                    LabeledContent("Account", value: account.email ?? "-")
                    LabeledContent("Status") {
                        if account.isSyncing {
                            ProgressView()
                        } else if account.lastError != nil {
                            Text("Failed").foregroundStyle(.red)
                        } else if let date = account.lastSynced {
                            Text("Synced \(date, format: .relative(presentation: .named))")
                        } else {
                            Text("Not synced yet")
                        }
                    }
                    LabeledContent("Devices", value: "\(account.remoteClients.count)")
                }
                Section {
                    Toggle("Open Tabs", isOn: $syncTabs)
                    Toggle("History", isOn: $syncHistory)
                    Toggle("Zen Workspaces", isOn: $syncWorkspaces)
                    Toggle("Passwords", isOn: $syncPasswords)
                } header: {
                    Text("Sync on This iPhone")
                } footer: {
                    Text("Turning one off stops it on this iPhone only; Zen keeps syncing it. Which devices' tabs show is under Workspaces.")
                }
                Section {
                    Button("Sync Now") { Task { await account.sync() } }
                        .disabled(account.isSyncing)
                    Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
                }
            } else {
                Section {
                    Button("Sign In to Mozilla Account") { showSignIn = true }
                } footer: {
                    Text("Sign in with the account you use in Zen to get its tabs, history and workspaces here.")
                }
            }
            if let error = account.lastError {
                Section("Last Error") { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            if let error = account.spacesError {
                Section("Workspaces Error") { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Sync")
        .onChange(of: [syncTabs, syncHistory, syncWorkspaces, syncPasswords]) { Task { await account.sync() } }
        .sheet(isPresented: $showSignIn) { SignInView() }
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }
}
