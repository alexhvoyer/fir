import SwiftUI
import WebKit

/// Experimental WebExtensions support on WebKit's extension API (iOS 18.4+). Extensions come from
/// addons.mozilla.org or a direct .xpi/.zip link; the requested permissions are granted at install.
@MainActor
@Observable
final class ExtensionManager: NSObject {
    static let shared = ExtensionManager()

    struct Installed: Identifiable {
        let id: String
        let name: String
        let version: String
        var isEnabled: Bool
        let context: WKWebExtensionContext
        var errors: [String] { context.errors.map(\.localizedDescription) }
    }

    @ObservationIgnored let controller = WKWebExtensionController(configuration: .default())
    @ObservationIgnored weak var browser: BrowserModel?
    @ObservationIgnored private lazy var window = ExtensionWindow(manager: self)
    private(set) var installed: [Installed] = []

    private static let indexKey = "extensions"
    private static var folder: URL { URL.applicationSupportDirectory.appending(path: "Extensions", directoryHint: .isDirectory) }

    override init() {
        super.init()
        controller.delegate = self
    }

    /// Loads what was installed before; called once at launch.
    func start(browser: BrowserModel) async {
        self.browser = browser
        let index = UserDefaults.standard.array(forKey: Self.indexKey) as? [[String: Any]] ?? []
        for entry in index {
            guard let id = entry["id"] as? String else { continue }
            try? await add(id: id, enabled: entry["enabled"] as? Bool ?? true)
        }
    }

    /// Accepts an addons.mozilla.org page or slug ("darkreader"), or a direct .xpi/.zip URL.
    func install(_ input: String) async throws {
        let download = try await Self.packageURL(for: input.trimmingCharacters(in: .whitespacesAndNewlines))
        let (temp, _) = try await URLSession.shared.download(from: download)
        defer { try? FileManager.default.removeItem(at: temp) }
        let id = UUID().uuidString
        do {
            // Unpacked, because the manifest may need fixing before WebKit reads it.
            try ZipExtractor.extract(temp, to: file(id))
            try Self.adaptManifest(in: file(id))
            try await add(id: id, enabled: true)
        } catch {
            try? FileManager.default.removeItem(at: file(id))
            throw error
        }
        saveIndex()
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        let context = installed[index].context
        if enabled { try? controller.load(context) } else { try? controller.unload(context) }
        installed[index].isEnabled = enabled
        saveIndex()
    }

    func remove(_ id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        try? controller.unload(installed[index].context)
        installed.remove(at: index)
        try? FileManager.default.removeItem(at: file(id))
        saveIndex()
    }

    /// The toolbar action, as a menu entry: shows the extension's popup if it has one.
    func performAction(_ id: String) {
        guard let entry = installed.first(where: { $0.id == id }) else { return }
        entry.context.performAction(for: browser?.selected.isPrivate == false ? browser?.selected : nil)
    }

    private func add(id: String, enabled: Bool) async throws {
        let webExtension = try await WKWebExtension(resourceBaseURL: file(id))
        let context = WKWebExtensionContext(for: webExtension)
        // Stable across launches, so the extension keeps its storage.
        context.uniqueIdentifier = id
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in webExtension.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        if enabled { try controller.load(context) }
        installed.append(Installed(
            id: id,
            name: webExtension.displayName ?? "Extension",
            version: webExtension.version ?? "",
            isEnabled: enabled,
            context: context
        ))
    }

    private func file(_ id: String) -> URL { Self.folder.appending(path: id, directoryHint: .isDirectory) }

    /// iOS runs background pages only non-persistent. A Manifest V2 background is persistent unless
    /// it says otherwise, and WebKit rejects that outright.
    private static func adaptManifest(in folder: URL) throws {
        let url = folder.appending(path: "manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              manifest["manifest_version"] as? Int == 2,
              var background = manifest["background"] as? [String: Any],
              background["persistent"] as? Bool != false else { return }
        background["persistent"] = false
        manifest["background"] = background
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
    }

    private func saveIndex() {
        UserDefaults.standard.set(installed.map { ["id": $0.id, "enabled": $0.isEnabled] }, forKey: Self.indexKey)
    }

    private static func packageURL(for input: String) async throws -> URL {
        if let url = URL(string: input), url.scheme != nil, ["xpi", "zip"].contains(url.pathExtension.lowercased()) {
            return url
        }
        // A listing URL ends in /addon/<slug>/; anything else is taken as the slug itself.
        let slug: String
        if let url = URL(string: input), let index = url.pathComponents.firstIndex(of: "addon"),
           index + 1 < url.pathComponents.count {
            slug = url.pathComponents[index + 1]
        } else {
            slug = input
        }
        guard let api = URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(slug)/") else { throw InstallError.notFound }
        let (data, response) = try await URLSession.shared.data(from: api)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["current_version"] as? [String: Any],
              let file = version["file"] as? [String: Any],
              let link = file["url"] as? String, let url = URL(string: link)
        else { throw InstallError.notFound }
        return url
    }

    enum InstallError: LocalizedError {
        case notFound
        var errorDescription: String? { "No such add-on on addons.mozilla.org." }
    }
}

extension ExtensionManager: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        browser?.open(configuration.url, in: nil)
        completionHandler(browser?.selected, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popup = action.popupViewController,
              let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController
        else { completionHandler(nil); return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        popup.modalPresentationStyle = .pageSheet
        top.present(popup, animated: true)
        completionHandler(nil)
    }
}

/// The one browser window extensions see; private tabs stay out of it.
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    private unowned let manager: ExtensionManager

    init(manager: ExtensionManager) {
        self.manager = manager
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        manager.browser?.tabs.filter { !$0.isPrivate } ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let selected = manager.browser?.selected, !selected.isPrivate else { return nil }
        return selected
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .fullscreen }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
}

extension BrowserTab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        ExtensionManager.shared.focusedWindow
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { title }
    func url(for context: WKWebExtensionContext) -> URL? { url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        ExtensionManager.shared.browser?.selectedID == id
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
        completionHandler(nil)
    }
}

extension ExtensionManager {
    var focusedWindow: (any WKWebExtensionWindow)? { window }
}
