import MozillaAppServices
import SwiftUI

/// Saved passwords, behind Face ID or the passcode each time the screen opens, as in Safari.
struct PasswordsView: View {
    @Environment(AccountService.self) private var account
    @State private var unlocked = false
    @State private var logins: [Login] = []
    @State private var query = ""

    var body: some View {
        Group {
            if unlocked {
                list
            } else {
                ContentUnavailableView {
                    Label("Passwords Are Locked", systemImage: "lock.fill")
                } actions: {
                    Button("Unlock") { Task { await unlock() } }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .navigationTitle("Passwords")
        .task { await unlock() }
    }

    private var list: some View {
        let shown = query.isEmpty ? logins : logins.filter {
            $0.origin.localizedCaseInsensitiveContains(query) || $0.username.localizedCaseInsensitiveContains(query)
        }
        return List {
            if logins.isEmpty {
                Text(account.isSignedIn
                     ? "No saved passwords yet. Passwords saved in Zen appear here after sync."
                     : "No saved passwords yet. Sign in to Sync to bring your passwords from Zen.")
                    .foregroundStyle(.secondary)
            }
            ForEach(shown, id: \.id) { login in
                NavigationLink {
                    PasswordDetailView(login: login) { reload() }
                } label: {
                    HStack(spacing: 12) {
                        SiteIcon(host: PasswordStore.host(login.origin), size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(PasswordStore.host(login.origin)).lineLimit(1)
                            Text(login.username.isEmpty ? "No username" : login.username)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search Passwords")
    }

    private func unlock() async {
        guard !unlocked else { return }
        guard AppLock.isAvailable else { unlocked = true; reload(); return }
        if await AppLock.authenticate(reason: "Show saved passwords") {
            unlocked = true
            reload()
        }
    }

    private func reload() {
        Task {
            logins = await Task.detached { PasswordStore.shared?.all() ?? [] }.value
        }
    }
}

private struct PasswordDetailView: View {
    let login: Login
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var revealed = false
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                LabeledContent("Website", value: PasswordStore.host(login.origin))
                LabeledContent("Username", value: login.username.isEmpty ? "-" : login.username)
                    .contextMenu { copyButton(login.username) }
                LabeledContent("Password") {
                    Text(revealed ? login.password : String(repeating: "•", count: 10))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                .contentShape(.rect)
                .onTapGesture { revealed.toggle() }
                .contextMenu { copyButton(login.password) }
            } footer: {
                Text("Tap the password to show it; touch and hold a field to copy it.")
            }
            Section {
                Button("Copy Password", systemImage: "doc.on.doc") { copy(login.password) }
                Button("Delete Password", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(PasswordStore.host(login.origin))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this password? It is deleted from Zen too.", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                PasswordStore.shared?.delete(login)
                onChange()
                dismiss()
            }
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button("Copy", systemImage: "doc.on.doc") { copy(text) }
    }

    /// Expires from the clipboard after two minutes, and stays off other devices.
    private func copy(_ text: String) {
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]],
                                      options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(120)])
    }
}
