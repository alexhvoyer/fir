import SwiftUI

/// Four pages shown once, on the first launch: what Fir is, Zen sync, the gestures nothing on
/// screen explains, and the few settings worth choosing up front.
struct OnboardingView: View {
    let onFinish: () -> Void
    @Environment(AccountService.self) private var account
    @State private var page = 0
    @State private var showSignIn = false
    @AppStorage(SettingsKey.searchEngine) private var engine = SearchEngine.duckDuckGo
    @AppStorage(SettingsKey.searchSuggestions) private var searchSuggestions = true
    @State private var blockAds = ContentBlocker.shared.isEnabled

    private static let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if page < Self.pageCount - 1 {
                    Button("Skip", action: onFinish).foregroundStyle(.secondary)
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 24)

            TabView(selection: $page) {
                welcome.tag(0)
                sync.tag(1)
                gestures.tag(2)
                setup.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            PageDots(count: Self.pageCount, current: page)
                .padding(.bottom, 20)
            Button(action: next) {
                Text(page == Self.pageCount - 1 ? "Start Browsing" : "Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .background(alignment: .top) {
            LinearGradient(colors: [Palette.teal.opacity(0.22), Palette.teal.opacity(0.06), .clear],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showSignIn) { SignInView() }
        .onChange(of: blockAds) { Task { await ContentBlocker.shared.setEnabled(blockAds) } }
        // Signing in from the sync page moves on by itself.
        .onChange(of: account.isSignedIn) { if account.isSignedIn, page == 1 { withAnimation { page = 2 } } }
    }

    private func next() {
        if page < Self.pageCount - 1 {
            withAnimation { page += 1 }
        } else {
            onFinish()
        }
    }

    // MARK: - Pages

    private var welcome: some View {
        OnboardingPage(title: "Welcome to Fir",
                       text: "A calm iPhone browser that brings along your Zen workspaces.") {
            SprigMark()
                .frame(width: 84, height: 84)
                .padding(18)
                .background(Palette.field, in: .rect(cornerRadius: 30, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        }
    }

    private var sync: some View {
        OnboardingPage(title: "Your tabs, everywhere",
                       text: "Sign in with the Mozilla account you use in Zen to bring its workspaces, pinned sites, open tabs and history to this iPhone.") {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(Palette.teal.gradient)
        } footer: {
            if account.isSignedIn {
                Label(account.email ?? "Signed in", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Sign In with Mozilla") { showSignIn = true }
                    .buttonStyle(.glass)
            }
            Text("Fir is an independent app, not affiliated with Zen or Mozilla.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var gestures: some View {
        // The list goes under the title: a footer, not art.
        OnboardingPage(title: "Gestures", text: nil) {
            EmptyView()
        } footer: {
            VStack(alignment: .leading, spacing: 18) {
                tip("arrow.left.and.right", "Swipe the address bar", "to move between tabs")
                tip("arrow.up", "Swipe up from the bar", "to see all tabs")
                tip("plus.square.on.square", "Swipe left on the last tab", "for a new one")
                tip("hand.tap", "Long-press the tabs button", "for a new or private tab")
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
    }

    /// The same settings as in Settings, as system rows: choosing here is choosing there.
    private var setup: some View {
        VStack(spacing: 12) {
            Text("Make it yours").font(.brandHeading(.largeTitle))
            Text("You can change these later in Settings.")
                .foregroundStyle(.secondary)
            Form {
                Section {
                    Picker("Search Engine", selection: $engine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                    }
                    Toggle("Search Suggestions", isOn: $searchSuggestions)
                } header: {
                    Text("Search")
                } footer: {
                    Text("Suggestions send what you type to the search engine.")
                }
                Section {
                    Toggle("Block Ads & Trackers", isOn: $blockAds)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Private tabs leave nothing behind. You can also lock Fir with Face ID in Settings.")
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
        }
        .padding(.top, 40)
    }

    private func tip(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.teal)
                .frame(width: 48, height: 48)
                .glassEffect(.regular, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}

private struct OnboardingPage<Art: View, Footer: View>: View {
    let title: LocalizedStringKey
    let text: LocalizedStringKey?
    @ViewBuilder let art: Art
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            art
            VStack(spacing: 12) {
                Text(title).font(.brandHeading(.largeTitle)).multilineTextAlignment(.center)
                if let text {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            footer
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }
}

extension OnboardingPage where Footer == EmptyView {
    init(title: LocalizedStringKey, text: LocalizedStringKey?, @ViewBuilder art: () -> Art) {
        self.init(title: title, text: text, art: art, footer: { EmptyView() })
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: index == current ? 20 : 8, height: 8)
            }
        }
        .animation(.snappy, value: current)
    }
}
