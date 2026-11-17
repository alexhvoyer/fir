import SwiftUI

/// The list shown once after an update. It has its own number: raise `list` and rewrite `items` only
/// when an update has something to tell, so most builds pass quietly.
enum WhatsNew {
    static let list = 3

    struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    @MainActor static var items: [Item] {
        [
            Item(symbol: "globe", title: String(localized: "Fir speaks your language"),
                 detail: String(localized: "Now in Spanish, French, German, Italian, Russian and Portuguese.")),
            Item(symbol: "ipad", title: String(localized: "Fir on iPad"),
                 detail: String(localized: "In every orientation, with Safari's keyboard shortcuts.")),
            Item(symbol: "rectangle.split.2x1", title: String(localized: "Made for iPhone Duo"),
                 detail: String(localized: "The controls sit in the camera column on both screens.")),
            Item(symbol: "key.fill", title: String(localized: "Use your own password manager"),
                 detail: String(localized: "Turn off Save and Fill Passwords in Settings > Passwords.")),
            Item(symbol: "doc.on.clipboard", title: String(localized: "Paste and Go in the bar"),
                 detail: String(localized: "A blank tab offers to paste what you copied.")),
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
