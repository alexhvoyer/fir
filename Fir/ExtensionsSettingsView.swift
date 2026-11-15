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
                Text(error ?? "Experimental. Installs Firefox add-ons from addons.mozilla.org through WebKit's extension support; many work, some don't. Permissions the add-on asks for are granted. Not available in private tabs.")
                    .foregroundStyle(error == nil ? Color.secondary : .red)
            }
            if !manager.installed.isEmpty {
                Section("Installed") {
                    ForEach(manager.installed) { item in
                        NavigationLink { ExtensionDetailView(id: item.id) } label: {
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

/// One add-on, as in Safari's settings: on or off, its own settings page, what it reported, removal.
private struct ExtensionDetailView: View {
    let id: String
    private let manager = ExtensionManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let item = manager.installed.first(where: { $0.id == id }) {
            List {
                Section {
                    Toggle("Enabled", isOn: Binding(get: { item.isEnabled }, set: { manager.setEnabled($0, for: id) }))
                    // Without a settings page, an add-on keeps its settings in its popup, as Dark Reader does.
                    Button("Extension Settings", systemImage: "gearshape") {
                        if item.hasSettings { manager.openSettings(id) } else { manager.performAction(id) }
                    }
                    .disabled(!item.isEnabled)
                } footer: {
                    Text("Version \(item.version)")
                }
                if !item.errors.isEmpty {
                    Section {
                        DisclosureGroup("\(item.errors.count) Reported \(item.errors.count == 1 ? "Problem" : "Problems")") {
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
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
