import SwiftUI

/// The list shown once after an update. It has its own number: raise `list` and rewrite `items` only
/// when an update has something to tell, so most builds pass quietly.
enum WhatsNew {
    static let list = 4

    struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    @MainActor static var items: [Item] {
        [
            Item(symbol: "magnifyingglass", title: String(localized: "Any search engine"),
                 detail: String(localized: "Add one by its address, or pick Kagi.")),
            Item(symbol: "bolt.fill", title: String(localized: "Quick Search"),
                 detail: String(localized: "Type a keyword and a space, like “wiki fir”.")),
            Item(symbol: "plus.magnifyingglass", title: String(localized: "Page Zoom like Safari"),
                 detail: String(localized: "A zoomed page still fits the screen width.")),
        ]
    }

    /// Onboarding has to be behind the user: a new install hears about everything there.
    static var isDue: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: SettingsKey.onboardingDone)
            && defaults.bool(forKey: SettingsKey.whatsNew, default: true)
            && defaults.integer(forKey: SettingsKey.whatsNewSeen) < list
    }

    static func markSeen() {
        UserDefaults.standard.set(list, forKey: SettingsKey.whatsNewSeen)
    }
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 32) {
                    Text("What's New").font(.brandHeading(.largeTitle))
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(WhatsNew.items) { FeatureRow($0.symbol, $0.title, $0.detail) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 24)
                .padding(.top, 48)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            Button {
                dismiss()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }
}
