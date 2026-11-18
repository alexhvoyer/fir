import Foundation

/// The share extension's Open in Fir: the page's address travels inside firbrowser://open?url=.
enum OpenInFir {
    static func url(for page: URL) -> URL? {
        var parts = URLComponents()
        parts.scheme = "firbrowser"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "url", value: page.absoluteString)]
        return parts.url
    }

    /// The page to open. Any app can call the scheme, so only web addresses pass, never file or script ones.
    static func target(of url: URL) -> URL? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "url" })?.value,
              let page = URL(string: value), isWeb(page) else { return nil }
        return page
    }

    static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host() != nil
    }
}
