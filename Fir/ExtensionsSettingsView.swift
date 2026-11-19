import SwiftUI

struct ExtensionsSettingsView: View {
    private let manager = ExtensionManager.shared
    @State private var source = ""
    @State private var installing = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                TextField("Add-on link or name, e.g. darkreader", text: $source)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit(install)
                Button(installing ? "Installing…" : "Install", action: install)
                    .disabled(installing || source.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text(error ?? String(localized: "Experimental. Installs Firefox add-ons from addons.mozilla.org through WebKit's extension support; many work, some don't. Permissions the add-on asks for are granted. Not available in private tabs."))
                    .foregroundStyle(error == nil ? Color.secondary : .red)
            }
            if !manager.installed.isEmpty {
                Section("Installed") { InstalledExtensionRows() }
            }
        }
        .navigationTitle("Extensions")
    }

    private func install() {
        let input = source
        installing = true
        error = nil
        Task {
            do {
                try await manager.install(input)
                // Only what was installed: a name typed meanwhile stays.
                if source == input { source = "" }
            } catch {
                self.error = error.localizedDescription
            }
            installing = false
        }
    }
}

/// The installed add-ons, each leading to its own page; shared by Settings and the page sheet.
private struct InstalledExtensionRows: View {
    /// The page sheet's tab; nil in Settings.
    var tab: BrowserTab?
    private let manager = ExtensionManager.shared

    var body: some View {
        ForEach(manager.installed) { item in
            NavigationLink { ExtensionDetailView(id: item.id, tab: tab) } label: {
                LabeledContent {
                    Text(item.isEnabled ? "On" : "Off")
                } label: {
                    Text(item.name).lineLimit(1)
                    Text(item.version)
                }
            }
            .swipeActions {
                Button("Remove", role: .destructive) { manager.remove(item.id) }
            }
        }
    }
}

/// The page sheet's Extensions page: every add-on, the switched-off ones too, so they can be turned back on.
struct PageExtensionsView: View {
    let tab: BrowserTab

    var body: some View {
        List { InstalledExtensionRows(tab: tab) }
            .overlay {
                // The last add-on was removed here.
                if ExtensionManager.shared.installed.isEmpty {
                    ContentUnavailableView("No Extensions", systemImage: "puzzlepiece.extension")
                }
            }
            .sheetPageHeader(Text("Extensions"))
    }
}

/// One add-on, as in Safari's settings: on or off, its own settings page, what it reported, removal.
private struct ExtensionDetailView: View {
    let id: String
    /// The page sheet's tab; nil in Settings.
    var tab: BrowserTab?
    private let manager = ExtensionManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let item = manager.installed.first(where: { $0.id == id }) {
            List {
                Section {
                    Toggle("Enabled", isOn: Binding(get: { item.isEnabled }, set: { manager.setEnabled($0, for: id) }))
                    // The popup, which the page sheet's menu used to offer beside the settings page.
                    if tab != nil, item.hasSettings {
                        Button("Open", systemImage: "puzzlepiece.extension") { manager.performAction(id) }
                            .disabled(!item.isEnabled)
                    }
                    // Without a settings page, an add-on keeps its settings in its popup, as Dark Reader does.
                    Button("Extension Settings", systemImage: "gearshape") {
                        if item.hasSettings { manager.openSettings(id) } else { manager.performAction(id) }
                    }
                    .disabled(!item.isEnabled)
                } footer: {
                    Text("Version \(item.version)")
                }
                if let tab, let url = tab.pageURL, let site = SiteSettings.site(url),
                   item.deniedSites.contains(site) || item.context.hasAccess(to: url) {
                    Section {
                        Toggle("Allow on \(site)", isOn: Binding(get: { !item.deniedSites.contains(site) }, set: {
                            manager.setAllowed($0, for: id, on: site)
                            tab.webView.reload()
                        }))
                        .disabled(!item.isEnabled)
                    } footer: {
                        Text("Only this site. The page reloads.")
                    }
                }
                // Settings only: in the page sheet the switch above already covers this site.
                if tab == nil, !item.deniedSites.isEmpty {
                    Section {
                        ForEach(item.deniedSites.sorted(), id: \.self) { site in
                            Text(site).swipeActions {
                                Button("Allow") { manager.setAllowed(true, for: id, on: site) }.tint(.green)
                            }
                        }
                    } header: {
                        Text("Off on These Sites")
                    } footer: {
                        Text("Swipe a site to allow the add-on there again.")
                    }
                }
                if !item.errors.isEmpty {
                    Section {
                        DisclosureGroup("\(item.errors.count) Reported Problems") {
                            ForEach(item.errors, id: \.self) {
                                Text($0).font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
                            }
                        }
                    } footer: {
                        Text("Messages the add-on reported. Many are harmless; if it doesn't work, the reason is usually here.")
                    }
                }
                Section {
                    Button("Remove Extension", role: .destructive) {
                        manager.remove(id)
                        dismiss()
                    }
                }
            }
            .sheetPageHeader(Text(item.name), when: tab != nil)
        }
    }
}
