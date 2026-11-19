import SwiftUI

/// The list shown once after an update. It has its own number: raise `list` and rewrite `items` only
/// when an update has something to tell, so most builds pass quietly.
enum WhatsNew {
    static let list = 5

    struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    @MainActor static var items: [Item] {
        [
            Item(symbol: "square.and.arrow.up", title: String(localized: "Share to Fir"),
                 detail: String(localized: "Open links in Fir or send them to a device from any app.")),
            Item(symbol: "puzzlepiece.extension", title: String(localized: "Extensions per site"),
                 detail: String(localized: "Turn one off for a site from the page menu.")),
            Item(symbol: "plus", title: String(localized: "A + for new tabs"),
                 detail: String(localized: "Put it in place of the tab count in Settings > Tabs.")),
            Item(symbol: "iphone", title: String(localized: "Better on iPhone Duo"),
                 detail: String(localized: "Pages fill the camera column; the open screen gets a wider grid.")),
            Item(symbol: "pencil", title: String(localized: "Your device's name"),
                 detail: String(localized: "Rename this iPhone for Send Tab in Settings > Sync.")),
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
