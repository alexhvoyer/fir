import SwiftUI
import WebKit

struct PrivacySettingsView: View {
    @State private var blockAds = ContentBlocker.shared.isEnabled
    @State private var lockApp = AppLock.isEnabled
    @AppStorage(SettingsKey.httpsOnly) private var httpsOnly = true
    @AppStorage(SettingsKey.lockPrivateTabs) private var lockPrivateTabs = false
    @State private var confirmClear = false
    @State private var cleared = false
    private let blocker = ContentBlocker.shared

    var body: some View {
        List {
            Section {
                Toggle("Block Ads and Trackers", isOn: $blockAds)
                if blockAds {
                    listToggle("Hide Cookie Pop-ups", id: "cookies")
                    listToggle("Hide Annoyances", id: "annoyances")
                    NavigationLink {
                        FilterListsView()
                    } label: {
                        LabeledContent("Filter Lists", value: blockerStatus)
                    }
                }
            } footer: {
                Text(blockAds
                     ? "Annoyances are newsletter and open-in-app pop-ups, chat and notification prompts, and social buttons. To turn blocking off for one site, use the page menu."
                     : "Ads and trackers load on every site.")
            }
            Section {
                Toggle("HTTPS-Only Mode", isOn: $httpsOnly)
            } footer: {
                Text("Always connects securely, and asks before opening a site that doesn't support it.")
            }
            Section {
                Toggle("Lock Private Tabs", isOn: $lockPrivateTabs)
                    .disabled(!AppLock.isAvailable && !lockPrivateTabs)
                Toggle("Lock Fir", isOn: $lockApp)
                    .disabled(!AppLock.isAvailable && !lockApp)
            } header: {
                Text("Face ID")
            } footer: {
                Text(AppLock.isAvailable
                     ? "Private tabs lock when you leave Private or Fir. Locking Fir asks when you open it, and hides the page in the app switcher."
                     : "Set up Face ID or a passcode on this iPhone to lock Fir.")
            }
            Section {
                Button("Clear Website Data", role: .destructive) { confirmClear = true }
            } footer: {
                Text(cleared ? "Website data cleared." : "Removes cookies, cache and site storage. You will be signed out of websites.")
            }
        }
        .navigationTitle("Privacy & Security")
        .onChange(of: blockAds) { Task { await blocker.setEnabled(blockAds) } }
        .onChange(of: lockApp) { old, new in
            guard new != AppLock.isEnabled else { return }
            Task {
                // On: proves the check works, so it can't lock you out. Off: only the owner may.
                if !(await AppLock.authenticate(reason: new ? "Turn on the Fir lock" : "Turn off the Fir lock")) {
                    lockApp = old
                    return
                }
                UserDefaults.standard.set(new, forKey: SettingsKey.lockApp)
            }
        }
        .onChange(of: lockPrivateTabs) { old, new in
            guard old, !new, AppLock.isAvailable else { return }
            Task { if !(await AppLock.authenticate(reason: "Turn off the private tabs lock")) { lockPrivateTabs = true } }
        }
        .confirmationDialog("Clear all website data?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                Task {
                    let store = WKWebsiteDataStore.default()
                    await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
                    cleared = true
                }
            }
        }
    }

    private func listToggle(_ title: String, id: String) -> some View {
        let list = FilterList.catalog.first { $0.id == id }!
        return Toggle(title, isOn: Binding(
            get: { blocker.isSelected(list) },
            set: { selected in Task { await blocker.setSelected(selected, list) } }
        ))
    }

    private var blockerStatus: String {
        switch blocker.state {
        case .off: "Off"
        case .loading: "Updating…"
        case .ready(let rules): "\(rules.formatted()) rules"
        case .failed(let message): message
        }
    }
}

/// Every filter list Fir can block with: the general ones, then one per language for regional sites.
private struct FilterListsView: View {
    private let blocker = ContentBlocker.shared

    var body: some View {
        List {
            Section {
                ForEach(FilterList.catalog.filter { !$0.isRegional }) { row($0) }
            }
            Section {
                ForEach(FilterList.catalog.filter(\.isRegional)) { row($0) }
            } header: {
                Text("Regional")
            } footer: {
                Text("General lists miss many ads on sites in other languages. Turn on the lists for the languages you read.")
            }
            Section {
                Button("Update Filter Lists") { Task { await blocker.update() } }
                    .disabled(blocker.state == .loading)
            } footer: {
                Text(footer)
            }
        }
        .navigationTitle("Filter Lists")
    }

    private func row(_ list: FilterList) -> some View {
        Toggle(isOn: Binding(
            get: { blocker.isSelected(list) },
            set: { selected in Task { await blocker.setSelected(selected, list) } }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(list.name)
                Text(list.detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: String {
        let updated = blocker.updated.map { "Updated \($0.formatted(.relative(presentation: .named)))." } ?? ""
        return "Lists update weekly. Changes apply from the next page load. \(updated)"
    }
}
