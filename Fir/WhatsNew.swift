import SwiftUI

/// The list shown once after an update. It has its own number: raise `list` and rewrite `items` only
/// when an update has something to tell, so most builds pass quietly.
enum WhatsNew {
    static let list = 1

    struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    @MainActor static var items: [Item] {
        var items = [
            Item(symbol: "pin", title: "A Pinned list on this iPhone",
                 detail: "Tabs you pin here move to a Pinned list, just like in Zen workspaces."),
            Item(symbol: "ellipsis.circle", title: "Pin from the card",
                 detail: "A card's menu can pin its tab or, in Zen workspaces, add it to Essentials."),
        ]
        if IntelligenceSearch.isSupported {
            items.insert(Item(symbol: "sparkles", title: "Intelligence Search",
                              detail: "Ask a question and Fir reads the first results for you, then writes one answer with its sources."),
                         at: 0)
        }
        return items
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
