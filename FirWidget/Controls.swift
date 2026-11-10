import SwiftUI
import WidgetKit

/// For Control Center, the Lock Screen and the Action Button; the same two as the icon's quick actions.
struct NewTabControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.khvoynitsky.browser.control.newTab") {
            ControlWidgetButton(action: NewTabIntent()) {
                Label("New Tab", systemImage: "plus")
            }
        }
        .displayName("New Tab")
        .description("Start a search in Fir.")
    }
}

struct NewPrivateTabControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.khvoynitsky.browser.control.newPrivateTab") {
            ControlWidgetButton(action: NewPrivateTabIntent()) {
                Label("New Private Tab", systemImage: "eyes")
            }
        }
        .displayName("New Private Tab")
        .description("Start a private search in Fir.")
    }
}
