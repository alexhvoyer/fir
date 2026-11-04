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

    private nonisolated static func fetchFromSite(_ host: String) async -> UIImage? {
        guard let root = URL(string: "https://\(host)/") else { return nil }
        var candidates: [URL] = []
        if let (data, response) = try? await URLSession.shared.data(from: root),
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
        for url in candidates {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data), image.size.width >= 16 else { continue }
            let icon = downscaled(image, to: 128)
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

    private nonisolated static func downscaled(_ image: UIImage, to side: CGFloat) -> UIImage {
        guard max(image.size.width, image.size.height) > side else { return image }
        let scale = side / max(image.size.width, image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
