import SwiftUI

/// Pages shown once, on the first launch: what Fir is, Zen sync, the gestures nothing on screen explains,
/// Intelligence Search where this iPhone can run it, and the few settings worth choosing up front.
struct OnboardingView: View {
    let onFinish: () -> Void
    @Environment(AccountService.self) private var account
    @State private var page = 0
    @State private var showSignIn = false
    @AppStorage(SettingsKey.searchEngine) private var engine = SearchEngine.duckDuckGo
    @AppStorage(SettingsKey.searchSuggestions) private var searchSuggestions = true
    @AppStorage(SettingsKey.intelligenceSearch) private var intelligenceSearch = true
    @State private var blockAds = ContentBlocker.shared.isEnabled

    private static let pageCount = IntelligenceSearch.isSupported ? 5 : 4

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
                if IntelligenceSearch.isSupported { intelligence.tag(3) }
                setup.tag(Self.pageCount - 1)
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

    private var intelligence: some View {
        OnboardingPage(title: "Intelligence Search",
                       text: "Ask a question and Fir reads the first results for you, then writes one answer with its sources. The answer is written on this iPhone.") {
            IntelligenceSearchDemo()
        } footer: {
            Toggle("Intelligence Search", isOn: $intelligenceSearch)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Palette.field, in: .capsule)
            if !IntelligenceSearch.isAvailable {
                Text("Turn on Apple Intelligence in iOS Settings to use it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
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

/// A made-up search playing on a loop: pages read one by one, then the answer. Nothing is loaded.
private struct IntelligenceSearchDemo: View {
    private static let sites = ["cooking.example", "kitchen.example", "recipes.example"]
    /// How many sites are showing; past their count, the answer takes over.
    @State private var stage = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("how to poach an egg", systemImage: "sparkles")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if stage <= Self.sites.count {
                ForEach(Array(Self.sites.prefix(stage).enumerated()), id: \.offset) { index, site in
                    HStack(spacing: 10) {
                        SiteIcon(host: site, size: 24, fetch: false)
                        Text(verbatim: site).font(.subheadline).lineLimit(1)
                        Spacer(minLength: 0)
                        if index < stage - 1 {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.teal)
                        } else {
                            ProgressView()
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Simmer it for about three minutes").font(.headline)
                    Text("🍳 Add a splash of vinegar [1]").font(.subheadline)
                    Text("🥄 Slide it in from a small bowl [2]").font(.subheadline)
                    Text("⏱ Lift it out with a slotted spoon [3]").font(.subheadline)
                }
                .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Fixed, so the page's text doesn't move as the demo plays.
        .frame(height: 170)
        .background(Palette.field, in: .rect(cornerRadius: 24, style: .continuous))
        .task {
            while !Task.isCancelled {
                for next in 0...(Self.sites.count + 1) {
                    withAnimation(reduceMotion ? nil : .smooth) { stage = next }
                    let pause: Duration = next > Self.sites.count ? .seconds(3.5) : .seconds(1)
                    try? await Task.sleep(for: pause)
                    guard !Task.isCancelled else { return }
                }
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
