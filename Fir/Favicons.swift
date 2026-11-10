import ImageIO
import UIKit

/// Site icons, taken from the site itself so no third-party icon service learns which sites are
/// pinned: first from its home page and usual paths, then from the real page once a tab loads it.
@MainActor
@Observable
final class Favicons {
    static let shared = Favicons()

    /// One observable box per site: an icon arriving redraws only that site's views, not every icon on
    /// screen as one shared dictionary did, which stuttered long lists like History.
    @Observable
    final class Icon {
        fileprivate(set) var image: UIImage?
    }

    @ObservationIgnored private var boxes: [String: Icon] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var adoptedFromPage: Set<String> = []

    /// A link tag's `rel`, absolute `href` and `sizes`.
    typealias Link = (rel: String, href: String, sizes: String?)

    /// Fetches once per launch; a home page that redirects to a sign-in screen may yield nothing.
    func icon(_ host: String) -> Icon {
        if let box = boxes[host] { return box }
        let box = Icon()
        boxes[host] = box
        return box
    }

    func load(_ host: String) async {
        let box = icon(host)
        guard box.image == nil, requested.insert(host).inserted else { return }
        // Read and decoded off the main thread: on it, each row scrolling in cost a file read.
        let file = Self.file(host)
        if let image = await Task.detached(priority: .userInitiated, operation: {
            UIImage(contentsOfFile: file.path)?.preparingForDisplay()
        }).value {
            box.image = image
            return
        }
        if let image = await Task.detached(priority: .utility, operation: { await Self.fetchFromSite(host) }).value {
            box.image = image
        }
    }

    /// Icons the loaded page declares; they beat the home-page guess (a signed-in app shows its own).
    func adopt(_ links: [Link], host: String) async {
        guard adoptedFromPage.insert(host).inserted else { return }
        let candidates = Self.ranked(links)
        if let image = await Task.detached(priority: .utility, operation: { await Self.firstImage(candidates, host: host) }).value {
            icon(host).image = image
        }
    }

    private nonisolated static func file(_ host: String) -> URL {
        URL.cachesDirectory.appending(path: "favicons/\(host).png")
    }

    /// No cookies or disk cache: a site's icon needs neither, and whatever the page names is fetched here.
    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    /// Up to `limit` bytes, or nil if there are more: pages name these files, and any size can be served.
    private nonisolated static func fetch(_ url: URL, limit: Int) async -> (data: Data, response: URLResponse)? {
        guard url.scheme == "https", let (bytes, response) = try? await session.bytes(from: url) else { return nil }
        guard response.expectedContentLength <= limit else {
            bytes.task.cancel()
            return nil
        }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit {
                    bytes.task.cancel()
                    return nil
                }
            }
        } catch {
            return nil
        }
        return (data, response)
    }

    private nonisolated static func fetchFromSite(_ host: String) async -> UIImage? {
        guard let root = URL(string: "https://\(host)/") else { return nil }
        var candidates: [URL] = []
        if let (data, response) = await fetch(root, limit: 2_000_000),
           let html = String(data: data.prefix(300_000), encoding: .utf8) ?? String(data: data.prefix(300_000), encoding: .isoLatin1) {
            // Links resolve against where redirects ended.
            let base = response.url ?? root
            let links: [Link] = html.matches(of: /<link\b[^>]*>/.ignoresCase()).compactMap { match in
                let tag = String(match.output)
                guard let rel = attribute("rel", in: tag), let href = attribute("href", in: tag),
                      let url = URL(string: href, relativeTo: base) else { return nil }
                return (rel, url.absoluteString, attribute("sizes", in: tag))
            }
            candidates = ranked(links)
        }
        candidates += ["/apple-touch-icon.png", "/favicon.ico"].compactMap { URL(string: $0, relativeTo: root) }
        return await firstImage(candidates, host: host)
    }

    /// Icon links, largest first. SVG and Safari's mask icons are skipped: UIImage can't draw them.
    private nonisolated static func ranked(_ links: [Link]) -> [URL] {
        let icons: [(url: URL, size: Int)] = links.compactMap { link in
            let rel = link.rel.lowercased()
            guard rel.contains("icon"), !rel.contains("mask"), !link.href.lowercased().contains(".svg"),
                  let url = URL(string: link.href) else { return nil }
            let declared = link.sizes?.split(separator: "x").first.flatMap { Int($0) }
            return (url, declared ?? (rel.contains("apple-touch") ? 180 : 32))
        }
        return icons.sorted { $0.size > $1.size }.map(\.url)
    }

    /// Downloads candidates in order and caches the first that decodes.
    private nonisolated static func firstImage(_ candidates: [URL], host: String) async -> UIImage? {
        for url in candidates.prefix(6) {
            guard let (data, _) = await fetch(url, limit: 2_000_000), let icon = thumbnail(data), icon.size.width >= 16 else { continue }
            if let png = icon.pngData() {
                try? FileManager.default.createDirectory(at: file(host).deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? png.write(to: file(host), options: .atomic)
            }
            return icon
        }
        return nil
    }

    private nonisolated static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = try? Regex("\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']").ignoresCase()
        guard let pattern, let match = tag.firstMatch(of: pattern) else { return nil }
        return match.output[1].substring.map(String.init)
    }

    /// Decoded at icon size: decoding in full, a tiny file claiming huge dimensions got the app killed.
    private nonisolated static func thumbnail(_ data: Data) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 128]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // An .ico holds several sizes, smallest often first.
        func width(_ index: Int) -> Int {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        }
        let largest = (0..<CGImageSourceGetCount(source)).max { width($0) < width($1) } ?? 0
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, largest, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
