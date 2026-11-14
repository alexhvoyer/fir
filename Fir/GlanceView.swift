import SwiftUI

/// A link's page from its preview, live in a sheet: it scrolls and follows links, and opens in a tab
/// once it's worth keeping. A link previewed here glances in a sheet over this one.
struct GlanceView: View {
    let glance: BrowserModel.Glance
    let depth: Int
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        NavigationStack {
            Preview(controller: glance.preview)
                .ignoresSafeArea(edges: .bottom)
                .toolbar(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Open in New Tab", systemImage: "plus.square.on.square") {
                            browser.glances = []
                            browser.open(glance.preview.pageURL, in: glance.tab.spaceID)
                        }
                        Spacer()
                        Button("Open", systemImage: "arrow.up.forward.square") {
                            browser.glances = []
                            glance.tab.load(glance.preview.pageURL)
                        }
                    }
                }
        }
        .sheet(item: browser.glance(at: depth + 1)) { GlanceView(glance: $0, depth: depth + 1) }
    }

    /// The preview's own controller, page and address strip, moved out of the closed context menu.
    private struct Preview: UIViewControllerRepresentable {
        let controller: LinkPreviewController
        func makeUIViewController(context: Context) -> LinkPreviewController { controller }
        func updateUIViewController(_ controller: LinkPreviewController, context: Context) {}
    }
}

extension BrowserModel {
    /// The glance at a depth of the stack; closing one closes those above it.
    func glance(at depth: Int) -> Binding<Glance?> {
        Binding(get: { self.glances.indices.contains(depth) ? self.glances[depth] : nil },
                set: { if $0 == nil { self.glances = Array(self.glances.prefix(depth)) } })
    }
}
