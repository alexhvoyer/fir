import NaturalLanguage
import SwiftUI
import Translation
import WebKit

/// Translates a page in place, as Safari does: the page's text nodes go through Apple's on-device
/// Translation in batches and are swapped for the result; Show Original puts them back.
enum PageTranslator {
    private static let world = WKContentWorld.world(name: "ZenTranslate")

    /// Visible text of the page, in document order; the nodes stay remembered for `apply`.
    @MainActor
    static func collect(from webView: WKWebView) async -> [String] {
        let script = """
            const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'CODE', 'PRE', 'TEXTAREA', 'SVG']);
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
              acceptNode(node) {
                if (!/\\p{L}/u.test(node.nodeValue)) return NodeFilter.FILTER_REJECT;
                for (let el = node.parentElement; el; el = el.parentElement) {
                  if (skip.has(el.tagName.toUpperCase()) || el.isContentEditable) return NodeFilter.FILTER_REJECT;
                }
                return NodeFilter.FILTER_ACCEPT;
              }
            });
            const nodes = [];
            while (walker.nextNode() && nodes.length < 3000) nodes.push(walker.currentNode);
            window.__zenNodes = nodes;
            window.__zenOriginals = window.__zenOriginals || new Map();
            return nodes.map(n => n.nodeValue.trim().slice(0, 4000));
            """
        return (try? await webView.callAsyncJavaScript(script, contentWorld: world) as? [String]) ?? []
    }

    /// Replaces node `index` with its translation, keeping the original's surrounding whitespace.
    @MainActor
    static func apply(_ translations: [(index: Int, text: String)], to webView: WKWebView) async {
        let pairs = translations.map { [$0.index as Any, $0.text] }
        _ = try? await webView.callAsyncJavaScript("""
            for (const [i, text] of pairs) {
              const node = window.__zenNodes && window.__zenNodes[i];
              if (!node) continue;
              if (!window.__zenOriginals.has(node)) window.__zenOriginals.set(node, node.nodeValue);
              const original = window.__zenOriginals.get(node);
              const lead = original.match(/^\\s*/)[0], tail = original.match(/\\s*$/)[0];
              node.nodeValue = lead + text + tail;
            }
            """, arguments: ["pairs": pairs], contentWorld: world)
    }

    @MainActor
    static func restore(_ webView: WKWebView) async {
        _ = try? await webView.callAsyncJavaScript("""
            if (window.__zenOriginals) for (const [node, text] of window.__zenOriginals) node.nodeValue = text;
            window.__zenOriginals = new Map();
            """, contentWorld: world)
    }

    /// The language people read: the system's first preferred one. Locale.current follows the app's own
    /// localizations, English only, so it would translate Russian pages into English.
    static var readerLanguage: Locale.Language {
        Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    /// The page's main language, guessed from its text; nil when there is too little to tell.
    @MainActor
    static func pageLanguage(_ webView: WKWebView) async -> Locale.Language? {
        // The page's own declaration first: guessing from text took Serbian Cyrillic for Russian.
        if let declared = try? await webView.evaluateJavaScript("document.documentElement.lang") as? String,
           let code = declared.split(separator: "-").first.map(String.init)?.lowercased(), code.count == 2 {
            return Locale.Language(identifier: code)
        }
        let sample = await collect(from: webView).joined(separator: " ").prefix(4000)
        guard let code = NLLanguageRecognizer.dominantLanguage(for: String(sample))?.rawValue, code != "und" else { return nil }
        return Locale.Language(identifier: code)
    }

    /// Runs inside `.translationTask`: the system asks to download the language there if needed.
    @MainActor
    static func translate(_ webView: WKWebView, with session: TranslationSession) async throws {
        let texts = await collect(from: webView)
        guard !texts.isEmpty else { return }
        // Batches, so the top of the page turns over before the rest is done.
        for start in stride(from: 0, to: texts.count, by: 80) {
            let range = start..<min(start + 80, texts.count)
            let requests = range.map { TranslationSession.Request(sourceText: texts[$0], clientIdentifier: String($0)) }
            let responses = try await session.translations(from: requests)
            await apply(responses.compactMap { response in
                response.clientIdentifier.flatMap(Int.init).map { ($0, response.targetText) }
            }, to: webView)
        }
    }
}
