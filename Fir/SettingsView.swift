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
                         detail: account.email ?? (account.isSignedIn ? String(localized: "Signed in") : String(localized: "Off"))) { SyncSettingsView() }
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

    private func link(_ title: LocalizedStringKey, icon: String, color: Color, detail: String? = nil,
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
    @AppStorage(SettingsKey.fullWidthPages) private var fullWidthPages = true
    @Environment(\.hasSideColumn) private var hasSideColumn
    @State private var isDefault: Bool?

    var body: some View {
        List {
            Section {
                // Unknown says nothing rather than "Not Fir": iOS stops answering for months at a time.
                LabeledContent("Default Browser", value: isDefault.map { $0 ? "Fir" : String(localized: "Not Fir") } ?? "")
                Button("Open iOS Settings") {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
            } footer: {
                if isDefault != true {
                    Text("In iOS Settings, choose Fir under Apps > Default Apps > Browser App. Links from other apps then open here.")
                }
            }
            Section {
                Toggle("Collapse Toolbar on Scroll", isOn: $collapseOnScroll)
                NavigationLink("Address Bar Buttons") { BarActionsView() }
                Toggle("Haptics", isOn: $haptics)
            }
            if hasSideColumn {
                Section {
                    Toggle("Full-Width Pages", isOn: $fullWidthPages)
                } footer: {
                    Text("Pages also fill the camera column. Its buttons float over the page and hide as you scroll.")
                }
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
            isDefault = DefaultBrowser.check()
        }
    }
}

private struct SearchSettingsView: View {
    @AppStorage(SettingsKey.searchEngine) private var engine = SearchEngine.duckDuckGo
    @AppStorage(SettingsKey.customSearchID) private var customID = SearchSites.legacyID
    @AppStorage(SettingsKey.searchSites) private var sites = SearchSites.initial
    @AppStorage(SettingsKey.searchSuggestions) private var searchSuggestions = true
    @AppStorage(SettingsKey.historySuggestions) private var historySuggestions = true
    @AppStorage(SettingsKey.intelligenceSearch) private var intelligenceSearch = true
    @State private var editing: String?

    var body: some View {
        List {
            Section {
                Picker("Search Engine", selection: defaultID) {
                    ForEach(sites.list.filter { $0.isValid || $0.id == defaultID.wrappedValue }) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.navigationLink)
            }
            Section {
                ForEach(sites.list) { site in
                    NavigationLink {
                        SearchSiteEditor(sites: $sites, id: site.id, onDelete: deleted)
                    } label: {
                        LabeledContent(site.title, value: site.trigger ?? String(localized: "Off"))
                    }
                }
                Button("Add Search Engine", systemImage: "plus") {
                    let site = SearchSite(id: UUID().uuidString, name: "", template: "", keyword: "", quickSearch: true)
                    sites.list.append(site)
                    editing = site.id
                }
            } header: {
                Text("Search Engines")
            } footer: {
                let example = "wiki fir"
                Text("Type a keyword and a space in the address bar, like “\(example)”, to search with that engine.")
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
        // Only for an engine just added: the rows push their own editors.
        .navigationDestination(item: $editing) { id in
            SearchSiteEditor(sites: $sites, id: id, onDelete: deleted)
        }
        // An added engine left without an address is dropped on the way back.
        .onChange(of: editing) { old, new in
            guard new == nil, let old, let site = sites.site(old), !site.isBuiltIn, site.template.isEmpty
            else { return }
            sites.list.removeAll { $0.id == old }
        }
    }

    /// The default goes back to DuckDuckGo when its engine is deleted.
    private func deleted(_ id: String) {
        if engine == .custom, customID == id { engine = .duckDuckGo }
    }

    /// Built-in engines with suggestions are their own setting; any other from the list is the custom one.
    private var defaultID: Binding<String> {
        Binding {
            // A custom default whose engine is gone searches DuckDuckGo, so the picker says so.
            engine != .custom ? engine.rawValue : sites.site(customID) == nil ? SearchEngine.duckDuckGo.rawValue : customID
        } set: { id in
            if let preset = SearchEngine(rawValue: id), preset != .custom {
                engine = preset
            } else {
                customID = id
                engine = .custom
            }
        }
    }
}

/// One engine's name, address and keyword; a built-in one keeps its name and address.
private struct SearchSiteEditor: View {
    @Binding var sites: SearchSites
    let id: String
    let onDelete: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let index = sites.list.firstIndex(where: { $0.id == id }) {
            let site = $sites.list[index]
            Form {
                Section {
                    LabeledContent("Name") {
                        if site.wrappedValue.isBuiltIn {
                            Text(site.wrappedValue.name)
                        } else {
                            TextField("Name", text: site.name).multilineTextAlignment(.trailing)
                        }
                    }
                }
                if !site.wrappedValue.isBuiltIn {
                    Section {
                        TextField(text: site.template, prompt: Text(verbatim: "https://example.org/search?q=%s")) {
                            Text("Search Address")
                        }
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    } header: {
                        Text("Search Address")
                    } footer: {
                        // Interpolated: a bare %s in the text would be read as a format specifier.
                        let mark = "%s"
                        if site.wrappedValue.template.isEmpty || site.wrappedValue.isValid {
                            Text("Type \(mark) where the search goes.")
                        } else {
                            Text("Needs a web address with \(mark) where the search goes. Until then, Fir searches with DuckDuckGo.")
                        }
                    }
                }
                Section {
                    Toggle("Quick Search", isOn: site.quickSearch)
                    LabeledContent("Keyword") {
                        TextField("Keyword", text: site.keyword, prompt: Text(verbatim: "wiki"))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .disabled(!site.wrappedValue.quickSearch)
                } footer: {
                    if sharesKeyword(site.wrappedValue) {
                        Text("Another engine has this keyword; the one higher in the list is used.")
                    }
                }
                if !site.wrappedValue.isBuiltIn {
                    Section {
                        Button("Delete Search Engine", role: .destructive) {
                            sites.list.remove(at: index)
                            onDelete(id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(site.wrappedValue.name.isEmpty ? String(localized: "New Search Engine") : site.wrappedValue.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func sharesKeyword(_ site: SearchSite) -> Bool {
        guard let trigger = site.trigger else { return false }
        return sites.list.contains { $0.id != site.id && $0.trigger == trigger }
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage(SettingsKey.appearance) private var appearance = Appearance.system
    @AppStorage(SettingsKey.accent) private var accent = Accent.system
    /// The alternate icon's name, nil for the default; iOS keeps it, this mirrors it for the list.
    @State private var icon = UIApplication.shared.alternateIconName

    private static let icons: [(name: String?, title: String, preview: String)] = [
        (nil, String(localized: "Snow"), "IconPreview-Default"),
        ("AppIcon-Night", String(localized: "Night"), "IconPreview-Night"),
        ("AppIcon-Spruce", String(localized: "Spruce"), "IconPreview-Spruce"),
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
    @State private var confirmSignOut = false
    @AppStorage(SettingsKey.syncTabs) private var syncTabs = true
    @AppStorage(SettingsKey.syncHistory) private var syncHistory = true
    @AppStorage(SettingsKey.syncWorkspaces) private var syncWorkspaces = true
    @AppStorage(SettingsKey.syncPasswords) private var syncPasswords = true
    @State private var showSignIn = false
    @State private var deviceName = ""
    @FocusState private var editingName: Bool

    var body: some View {
        List {
            if account.isSignedIn {
                Section {
                    LabeledContent("Account", value: account.email ?? "-")
                    LabeledContent("Device Name") {
                        TextField("Device Name", text: $deviceName, prompt: Text(account.deviceName ?? ""))
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.done)
                            .focused($editingName)
                            .onSubmit { account.rename(deviceName) }
                            .onChange(of: deviceName) { _, name in
                                if name.count > AccountService.deviceNameLimit { deviceName = String(name.prefix(AccountService.deviceNameLimit)) }
                            }
                    }
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
                } footer: {
                    Text("How Zen and your other devices list this iPhone, as in Send Tab to Device.")
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
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                            Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
                        } message: {
                            Text("Passwords and history are removed from this iPhone. What has synced stays in your Mozilla account.")
                        }
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
        // The field shows the account's name; leaving it, by Done or by going back, saves what was typed.
        .onAppear { deviceName = account.deviceName ?? "" }
        .onChange(of: account.deviceName) { if !editingName { deviceName = account.deviceName ?? "" } }
        .onChange(of: editingName) {
            guard !editingName else { return }
            account.rename(deviceName)
            // An emptied field shows the current name again; a typed one stays until the server confirms it.
            if deviceName.trimmingCharacters(in: .whitespaces).isEmpty { deviceName = account.deviceName ?? "" }
        }
        .onDisappear { account.rename(deviceName) }
        .onChange(of: [syncTabs, syncHistory, syncWorkspaces, syncPasswords]) { Task { await account.sync() } }
        .sheet(isPresented: $showSignIn) { SignInView() }
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }
}

/// The address bar's buttons, in edit mode as iOS lists are customised: drag to reorder, minus to remove,
/// plus to add.
private struct BarActionsView: View {
    @AppStorage(SettingsKey.barActions) private var stored = BarAction.encode(BarAction.defaults)

    var body: some View {
        let shown = BarAction.decode(stored)
        let more = BarAction.allCases.filter { !shown.contains($0) }
        let full = shown.count >= BarAction.limit
        List {
            Section {
                ForEach(shown) { Label($0.name, systemImage: $0.symbol) }
                    .onMove { from, to in
                        var actions = shown
                        actions.move(fromOffsets: from, toOffset: to)
                        stored = BarAction.encode(actions)
                    }
                    .onDelete { offsets in
                        var actions = shown
                        actions.remove(atOffsets: offsets)
                        stored = BarAction.encode(actions)
                    }
            } header: {
                Text("Shown")
            } footer: {
                Text("Up to three. While Back and Forward are shown, only the last one stays, to leave room for the address.")
            }
            if !more.isEmpty {
                Section("More Buttons") {
                    // Ids apart from the Shown rows': sharing them, an added row kept this cell, without
                    // its delete and reorder controls.
                    ForEach(more, id: \.addRowID) { action in
                        HStack {
                            // Borderless, so the plus alone adds, as iOS insert controls do.
                            Button("Add \(action.name)", systemImage: "plus.circle.fill") {
                                withAnimation { stored = BarAction.encode(shown + [action]) }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            // Set colours don't grey out by themselves.
                            .foregroundStyle(.white, full ? .gray : .green)
                            .font(.title3)
                            .disabled(full)
                            Label(action.name, systemImage: action.symbol)
                        }
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Address Bar Buttons")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension BarAction {
    var addRowID: String { "add." + rawValue }
}
