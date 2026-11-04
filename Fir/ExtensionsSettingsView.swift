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
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(isOn: Binding(get: { item.isEnabled }, set: { manager.setEnabled($0, for: item.id) })) {
                                VStack(alignment: .leading) {
                                    Text(item.name)
                                    Text(item.version).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            ForEach(item.errors, id: \.self) {
                                Text($0).font(.caption2).foregroundStyle(.red)
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
                source = ""
            } catch {
                self.error = error.localizedDescription
            }
            installing = false
        }
    }
}
