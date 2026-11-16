import SwiftUI

/// Safari's keyboard shortcuts, for an iPad or an iPhone with a keyboard. They show in the iPad menu bar
/// and in the list that holding Command brings up.
struct KeyCommands: Commands {
    let browser: BrowserModel
    /// Greys the items out; each action checks the lock again when pressed, as the menu can lag a lock.
    let locked: Bool

    private var pageLocked: Bool { locked || (browser.selected.isPrivate && browser.privateLocked) }
    /// Live, not the menu's state: nothing may act behind the lock window or on a locked private page.
    private var appBlocked: Bool { LockWindow.isShown }
    private var pageBlocked: Bool { LockWindow.isShown || (browser.selected.isPrivate && browser.privateLocked) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { if !appBlocked { browser.searchRequested = .tab } }
                .keyboardShortcut("t")
                .disabled(locked)
            Button("New Private Tab") { if !appBlocked { browser.searchRequested = .privateTab } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(locked)
            Button("Open Location") { onPage { browser.searchRequested = .address } }
                .keyboardShortcut("l")
                .disabled(pageLocked)
            Button("Close Tab") { onPage { browser.close(browser.selected) } }
                .keyboardShortcut("w")
                .disabled(pageLocked)
        }
        // Into the system's own View menu: a menu of that name of our own showed twice.
        CommandGroup(after: .toolbar) {
            Group {
                Button("Reload") { onPage { browser.selected.webView.reload() } }
                    .keyboardShortcut("r")
                Button("Find on Page") {
                    onPage { browser.selected.webView.findInteraction?.presentFindNavigator(showingReplace: false) }
                }
                .keyboardShortcut("f")
                Divider()
                Button("Back") { onPage { browser.goBack() } }
                    .keyboardShortcut("[")
                Button("Forward") { onPage { browser.goForward() } }
                    .keyboardShortcut("]")
                Divider()
                Button("Show Next Tab") { onPage { step(1) } }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Show Previous Tab") { onPage { step(-1) } }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
            }
            .disabled(pageLocked)
        }
    }

    private func onPage(_ action: () -> Void) {
        if !pageBlocked { action() }
    }

    /// The neighbour in the same workspace, round from the last to the first, as Safari does.
    private func step(_ offset: Int) {
        let tabs = browser.tabs(in: browser.selected.spaceID)
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == browser.selectedID }) else { return }
        browser.select(tabs[(index + offset + tabs.count) % tabs.count])
    }
}
