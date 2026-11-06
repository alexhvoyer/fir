import SwiftUI
import WebKit

/// A page's article as Mozilla's Readability (the engine behind Firefox's Reader View) extracts it.
struct ReaderArticle: Identifiable {
    let id = UUID()
    let title: String
    let byline: String?
    let siteName: String?
    let html: String
    /// The article's plain text.
    let text: String
    let url: URL

    private static let world = WKContentWorld.world(name: "ZenReader")
    private static let source = Bundle.main.url(forResource: "Readability", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    /// Nil when the page has no article to speak of. Runs in its own world, on a copy of the document.
    @MainActor
    static func extract(from webView: WKWebView) async -> ReaderArticle? {
        guard let url = webView.url, !source.isEmpty else { return nil }
        let script = source + """
            ;
            // Sites whose article Readability misses: parse just their article body. Their media sit in
            // "media" and "header" classes, which Readability scores as clutter and drops.
            const rules = [{ host: /(^|\\.)(dtf|vc)\\.ru$/, root: '.content__body', author: '.content-header .author__name' }];
            const rule = rules.find(r => r.host.test(location.hostname));
            const root = rule && document.querySelector(rule.root);
            let doc = document.cloneNode(true);
            if (root) {
              doc = document.implementation.createHTMLDocument(document.title);
              const body = doc.createElement('article');
              body.innerHTML = root.innerHTML;
              doc.body.append(body);
              for (const el of doc.querySelectorAll('[class]')) {
                if (/media|header/i.test(el.getAttribute('class'))) el.removeAttribute('class');
              }
            }
            const article = new Readability(doc).parse();
            if (!article || !article.content) return null;
            // The page's own headline over a <title> that carries the site name.
            const h1 = document.querySelector('h1')?.textContent.trim();
            const title = h1 && document.title.startsWith(h1) ? h1 : article.title || '';
            // Scripts are off in the reader, so videos need the browser's own controls.
            const content = article.content.replace(/<video /g, '<video controls ');
            // A rule's own author: Readability can take one from a post embedded in the article.
            const author = rule && document.querySelector(rule.author)?.textContent.trim();
            return { title, byline: author || article.byline, siteName: article.siteName, content, text: article.textContent };
            """
        guard let result = try? await webView.callAsyncJavaScript(script, contentWorld: world) as? [String: Any],
              let html = result["content"] as? String else { return nil }
        return ReaderArticle(title: result["title"] as? String ?? "", byline: result["byline"] as? String,
                             siteName: result["siteName"] as? String, html: html, text: result["text"] as? String ?? "", url: url)
    }
}

/// The article alone, in Zen's paper and graphite, with adjustable text size.
struct ReaderView: View {
    let article: ReaderArticle
    /// A link tapped in the article; it opens in the tab.
    let onOpen: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("readerTextSize") private var textSize = 19.0
    @AppStorage(SettingsKey.accent) private var accent = Accent.system
    /// The buttons step aside while reading down, as Safari's bar does, and come back on scrolling up.
    @State private var buttonsHidden = false

    var body: some View {
        ReaderWebView(html: page, baseURL: article.url, onOpen: { url in
            dismiss()
            onOpen(url)
        }, onScroll: { down in
            guard down != buttonsHidden else { return }
            withAnimation(.smooth(duration: 0.3)) { buttonsHidden = down }
        })
        .ignoresSafeArea(edges: .bottom)
        .background(colorScheme == .dark ? Palette.ink : Palette.paper)
        // Over the article, not above it: the text runs to the top once the buttons slide away.
        .overlay(alignment: .top) {
            HStack {
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                Spacer()
                HStack(spacing: 0) {
                    Button("Smaller Text", systemImage: "textformat.size.smaller") { textSize = max(14, textSize - 2) }
                        .frame(width: 48, height: 44)
                    Button("Larger Text", systemImage: "textformat.size.larger") { textSize = min(32, textSize + 2) }
                        .frame(width: 48, height: 44)
                }
                .labelStyle(.iconOnly)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .offset(y: buttonsHidden ? -90 : 0)
            .opacity(buttonsHidden ? 0 : 1)
        }
    }

    private var page: String {
        let dark = colorScheme == .dark
        // The chosen accent, resolved for this theme; system blue unless the user picked another.
        let link = UIColor(accent.color ?? .blue).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        let linkCSS = link.hexString
        let meta = [article.siteName, article.byline].compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
        return """
            <!doctype html><html><head>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              :root { color-scheme: \(dark ? "dark" : "light"); }
              body { margin: 0; padding: 64px 22px 80px; background: \(dark ? "#1F1F1F" : "#F2F0E3");
                     color: \(dark ? "#E6E3D6" : "#2A2A28"); font: \(Int(textSize))px/1.6 -apple-system, sans-serif;
                     -webkit-text-size-adjust: none; overflow-wrap: break-word; }
              h1 { font-size: 1.6em; line-height: 1.2; margin: 0.4em 0 0.3em; }
              .meta { color: \(dark ? "#9C9A90" : "#76736A"); font-size: 0.82em; margin-bottom: 1.6em; }
              a { color: \(linkCSS); text-decoration: none; }
              img, video, figure { max-width: 100%; height: auto; border-radius: 10px; }
              figure { margin: 1.2em 0; } figcaption { font-size: 0.8em; color: \(dark ? "#9C9A90" : "#76736A"); }
              pre, code { font-size: 0.85em; white-space: pre-wrap; }
              blockquote { margin: 1em 0; padding-left: 1em; border-left: 3px solid \(linkCSS); }
              table { display: block; overflow-x: auto; }
              svg { display: none; }
            </style></head><body>
            <h1>\(Self.escape(article.title))</h1>
            \(meta.isEmpty ? "" : "<div class=\"meta\">\(Self.escape(meta))</div>")
            \(article.html)
            </body></html>
            """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Shows the article with scripts off: Readability strips them, this makes sure none run.
private struct ReaderWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL
    let onOpen: (URL) -> Void
    /// True while scrolling down past the top, false on scrolling up or back at the top.
    let onScroll: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen, onScroll: onScroll) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        webView.scrollView.delegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpen = onOpen
        context.coordinator.onScroll = onScroll
        guard context.coordinator.shown != html else { return }
        context.coordinator.shown = html
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        var onOpen: (URL) -> Void
        var onScroll: (Bool) -> Void
        var shown: String?
        private var lastY: CGFloat = 0

        init(onOpen: @escaping (URL) -> Void, onScroll: @escaping (Bool) -> Void) {
            self.onOpen = onOpen
            self.onScroll = onScroll
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let y = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            defer { lastY = y }
            // Small moves are ignored, so a resting finger doesn't flicker the buttons.
            guard abs(y - lastY) > 2 else { return }
            onScroll(y > 40 && y > lastY)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            await MainActor.run { onOpen(url) }
            return .cancel
        }
    }
}

private extension UIColor {
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let clamp = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }
}
