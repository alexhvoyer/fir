import SwiftUI
import WebKit

/// Experimental WebExtensions support on WebKit's extension API (iOS 18.4+). Extensions come only from
/// addons.mozilla.org; the requested permissions are granted at install.
@MainActor
@Observable
final class ExtensionManager: NSObject {
    static let shared = ExtensionManager()

    struct Installed: Identifiable {
        let id: String
        let name: String
        let version: String
        var isEnabled: Bool
        /// Sites (as SiteSettings names them) where it is switched off.
        var deniedSites: Set<String> = []
        let context: WKWebExtensionContext
        var errors: [String] { context.errors.map(\.localizedDescription) }
        var hasSettings: Bool { context.optionsPageURL != nil }
    }

    @ObservationIgnored let controller = WKWebExtensionController(configuration: .default())
    @ObservationIgnored weak var browser: BrowserModel?
    @ObservationIgnored private lazy var window = ExtensionWindow(manager: self)
    /// Add-on pages showing in their sheets, each a tab to its add-on.
    @ObservationIgnored fileprivate(set) var pageTabs: [ExtensionPageTab] = []
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
            try? await add(id: id, enabled: entry["enabled"] as? Bool ?? true,
                           deniedSites: Set(entry["deniedSites"] as? [String] ?? []))
        }
    }

    /// Accepts an addons.mozilla.org page or slug ("darkreader").
    func install(_ input: String) async throws {
        let download = try await Self.packageURL(for: input.trimmingCharacters(in: .whitespacesAndNewlines))
        let (temp, _) = try await URLSession.shared.download(from: download)
        defer { try? FileManager.default.removeItem(at: temp) }
        let id = UUID().uuidString
        let folder = file(id)
        do {
            // Unpacked, because the manifest may need fixing before WebKit reads it. Off the main thread:
            // a large add-on froze the screen.
            try await Task.detached(priority: .userInitiated) {
                try ZipExtractor.extract(temp, to: folder)
                try Self.adapt(in: folder)
            }.value
            guard await Self.confirm(try await WKWebExtension(resourceBaseURL: folder)) else {
                try? FileManager.default.removeItem(at: folder)
                return
            }
            try await add(id: id, enabled: true)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        saveIndex()
    }

    /// Permissions are granted whole at install, so the sites it gets are named first.
    private static func confirm(_ webExtension: WKWebExtension) async -> Bool {
        let patterns = webExtension.allRequestedMatchPatterns
        let hosts = patterns.compactMap(\.host).filter { !$0.isEmpty }.sorted()
        // The add-on's own text: one short line, so it can't push the rest out of view.
        let name = String((webExtension.displayName ?? String(localized: "This add-on")).prefix { !$0.isNewline }.prefix(40))
        // Whole sentences, so each language can order them its own way.
        var message = if patterns.contains(where: \.matchesAllHosts) || hosts.contains("*") {
            String(localized: "\"\(name)\" will be able to read and change every website.")
        } else if hosts.isEmpty {
            String(localized: "\"\(name)\" will be able to read and change no websites.")
        } else if hosts.count > 5 {
            String(localized: "\"\(name)\" will be able to read and change \(hosts.prefix(5).joined(separator: ", ")) and \(hosts.count - 5) more.")
        } else {
            String(localized: "\"\(name)\" will be able to read and change \(hosts.formatted(.list(type: .and))).")
        }
        let extras = Self.notablePermissions(webExtension.requestedPermissions)
        if !extras.isEmpty {
            message += "\n\n" + String(localized: "It will also be able to:") + "\n" + extras.joined(separator: "\n")
        }
        return await PageDialog.present(message, host: String(localized: "Install Add-on?"), cancel: String(localized: "Cancel"),
                                        confirm: String(localized: "Install")) != nil
    }

    /// What Firefox warns about at install, among what WebKit supports; storage, alarms and menus need no warning.
    private static func notablePermissions(_ permissions: Set<WKWebExtension.Permission>) -> [String] {
        var lines: [String] = []
        if permissions.contains(.tabs) { lines.append(String(localized: "See the addresses of your open tabs")) }
        if permissions.contains(.webNavigation) { lines.append(String(localized: "See the pages you open as they load")) }
        if !permissions.isDisjoint(with: [.declarativeNetRequest, .declarativeNetRequestWithHostAccess]) {
            lines.append(String(localized: "Block content on any page"))
        }
        if permissions.contains(.declarativeNetRequestFeedback) { lines.append(String(localized: "Read your browsing history")) }
        if permissions.contains(.clipboardWrite) { lines.append(String(localized: "Put text on your clipboard")) }
        if permissions.contains(.nativeMessaging) { lines.append(String(localized: "Exchange messages with other apps")) }
        if permissions.contains(.unlimitedStorage) { lines.append(String(localized: "Store unlimited data on this device")) }
        return lines
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        let context = installed[index].context
        if enabled { try? controller.load(context) } else { try? controller.unload(context) }
        installed[index].isEnabled = enabled
        saveIndex()
    }

    /// Pages already open on the site keep what the add-on did until they reload.
    func setAllowed(_ allowed: Bool, for id: String, on site: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        Self.apply(allowed, on: site, to: installed[index].context)
        if allowed { installed[index].deniedSites.remove(site) } else { installed[index].deniedSites.insert(site) }
        saveIndex()
    }

    /// A denial outranks the sites granted at install. Allowing again restores the grant when the add-on asked
    /// for exactly this site, since the denial replaced it.
    static func apply(_ allowed: Bool, on site: String, to context: WKWebExtensionContext) {
        let requested = context.webExtension.allRequestedMatchPatterns
        for host in [site, "www." + site] {
            guard let pattern = try? WKWebExtension.MatchPattern(string: "*://\(host)/*") else { continue }
            let status: WKWebExtensionContext.PermissionStatus =
                allowed ? (requested.contains(pattern) ? .grantedExplicitly : .unknown) : .deniedExplicitly
            context.setPermissionStatus(status, for: pattern)
        }
    }

    func remove(_ id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        try? controller.unload(installed[index].context)
        installed.remove(at: index)
        try? FileManager.default.removeItem(at: file(id))
        saveIndex()
    }

    // WebKit knows only the tabs it was told about at load; add-ons rely on these for their tab events.

    func tabsChanged(from old: [BrowserTab], to new: [BrowserTab]) {
        guard !installed.isEmpty else { return }
        let before = Set(old.map(\.id)), after = Set(new.map(\.id))
        for tab in new where !before.contains(tab.id) && !tab.isPrivate { controller.didOpenTab(tab) }
        for tab in old where !after.contains(tab.id) && !tab.isPrivate { controller.didCloseTab(tab, windowIsClosing: false) }
    }

    func tabActivated(_ tab: BrowserTab, previous: BrowserTab?) {
        guard !installed.isEmpty, !tab.isPrivate else { return }
        controller.didActivateTab(tab, previousActiveTab: previous?.isPrivate == false ? previous : nil)
    }

    func tabChanged(_ tab: BrowserTab, _ properties: WKWebExtension.TabChangedProperties) {
        guard !installed.isEmpty, !tab.isPrivate, browser?.tabs.contains(where: { $0 === tab }) == true else { return }
        controller.didChangeTabProperties(properties, for: tab)
    }

    /// The add-on's options page, in its sheet.
    func openSettings(_ id: String) {
        guard let context = installed.first(where: { $0.id == id && $0.isEnabled })?.context,
              let url = context.optionsPageURL else { return }
        Self.showPage(url, of: context)
    }

    /// An add-on's own page (options, welcome) in a sheet. Only a web view made from the add-on's
    /// configuration loads its pages; a tab's failed with "resource unavailable".
    @discardableResult
    private static func showPage(_ url: URL, of context: WKWebExtensionContext) -> ExtensionPageTab? {
        guard let configuration = context.webViewConfiguration, let presenter = topViewController() else { return nil }
        let page = ExtensionPageController(url: url, base: context.baseURL, configuration: configuration)
        page.navigationItem.title = context.webExtension.displayName
        let sheet = UINavigationController(rootViewController: page)
        page.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak sheet] _ in
            sheet?.dismiss(animated: true)
        })
        presenter.present(sheet, animated: true)
        let tab = ExtensionPageTab(page: page, context: context)
        page.extensionTab = tab
        shared.pageTabs.append(tab)
        // Only its owner hears of it.
        context.didOpenTab(tab)
        return tab
    }

    /// Only its own: another add-on's page is none of its business.
    func pageTabs(of context: WKWebExtensionContext) -> [ExtensionPageTab] {
        pageTabs.filter { $0.context === context }
    }

    fileprivate func pageClosed(_ tab: ExtensionPageTab) {
        guard let index = pageTabs.firstIndex(where: { $0 === tab }) else { return }
        pageTabs.remove(at: index)
        tab.context?.didCloseTab(tab, windowIsClosing: false)
    }

    private static func topViewController() -> UIViewController? {
        var top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    /// Shows the add-on's popup. The tab gets temporary access, so only the page the user is on, never a
    /// private tab or a site it's switched off on.
    func performAction(_ id: String, for tab: BrowserTab?) {
        guard let entry = installed.first(where: { $0.id == id }) else { return }
        let denied = SiteSettings.site(tab?.pageURL).map(entry.deniedSites.contains) ?? false
        entry.context.performAction(for: tab?.isPrivate == false && !denied ? tab : nil)
    }

    private func add(id: String, enabled: Bool, deniedSites: Set<String> = []) async throws {
        let folder = file(id)
        // Add-ons installed before an adaptation existed get it once, off the main thread.
        // A failure leaves it as it was installed, still loading.
        if !Self.isAdapted(folder) { try? await Task.detached(priority: .userInitiated) { try Self.adapt(in: folder) }.value }
        let webExtension = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: webExtension)
        // Stable across launches, so the extension keeps its storage.
        context.uniqueIdentifier = id
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in webExtension.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        for site in deniedSites { Self.apply(false, on: site, to: context) }
        if enabled { try controller.load(context) }
        installed.append(Installed(
            id: id,
            name: webExtension.displayName ?? String(localized: "Extension"),
            version: webExtension.version ?? "",
            isEnabled: enabled,
            deniedSites: deniedSites,
            context: context
        ))
    }

    private func file(_ id: String) -> URL { Self.folder.appending(path: id, directoryHint: .isDirectory) }

    /// Bumped when `adapt` learns something new, so installed add-ons get it once more.
    private static let adaptation = "1"
    private static let adaptationMarker = ".fir-adapted"

    nonisolated private static func isAdapted(_ folder: URL) -> Bool {
        (try? String(contentsOf: folder.appending(path: adaptationMarker), encoding: .utf8)) == adaptation
    }

    /// Makes a Firefox add-on fit WebKit: rewritten files only, never new permissions.
    nonisolated private static func adapt(in folder: URL) throws {
        let url = folder.appending(path: "manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { return }
        if manifest["manifest_version"] as? Int == 2, var background = manifest["background"] as? [String: Any] {
            // iOS runs background pages only non-persistent, and WebKit rejects a persistent one outright.
            if background["persistent"] as? Bool != false { background["persistent"] = false }
            // Stand-ins for Firefox APIs WebKit lacks, loaded before the add-on's own background code.
            if let shims = Bundle.main.url(forResource: "ExtensionShims", withExtension: "js") {
                let target = folder.appending(path: shimsFile)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: shims, to: target)
                if var scripts = background["scripts"] as? [String] {
                    if !scripts.contains(shimsFile) { scripts.insert(shimsFile, at: 0) }
                    background["scripts"] = scripts
                } else if let page = background["page"] as? String {
                    // Only a page inside the add-on: a manifest's "../" must not reach another add-on's files.
                    let target = folder.appending(path: page).standardizedFileURL
                    if target.path.hasPrefix(folder.standardizedFileURL.path + "/") { try insertShims(intoPage: target) }
                }
            }
            manifest["background"] = background
        }
        // WebKit reports an empty list as a broken manifest; Firefox add-ons that register scripts later ship one.
        if (manifest["content_scripts"] as? [Any])?.isEmpty == true { manifest["content_scripts"] = nil }
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)

        let gecko = ((manifest["browser_specific_settings"] ?? manifest["applications"]) as? [String: Any])?["gecko"] as? [String: Any]
        let isTampermonkey = gecko?["id"] as? String == "firefox@tampermonkey.net"
        try rewriteSources(in: folder) { text in
            // Firefox add-ons recognise their own pages by Firefox's scheme.
            var text = text.replacingOccurrences(of: "moz-extension:", with: "webkit-extension:")
            // Its default needs Firefox's userScripts API; content mode runs through the stand-in above.
            if isTampermonkey {
                text = text.replacingOccurrences(of: #"runtime_content_mode:"userscripts""#, with: #"runtime_content_mode:"content""#)
            }
            return text
        }
        try adaptation.write(to: folder.appending(path: adaptationMarker), atomically: true, encoding: .utf8)
    }

    private static let shimsFile = "fir-shims.js"

    nonisolated private static func insertShims(intoPage url: URL) throws {
        var html = try String(contentsOf: url, encoding: .utf8)
        guard !html.contains(shimsFile) else { return }
        let tag = "<script src=\"/\(shimsFile)\"></script>"
        if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            html.insert(contentsOf: tag, at: head.upperBound)
        } else {
            html = tag + html
        }
        try html.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Rewrites the add-on's scripts and pages in place; files that aren't UTF-8 text stay as they are.
    nonisolated private static func rewriteSources(in folder: URL, _ change: (String) -> String) throws {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files where ["js", "html", "htm"].contains(file.pathExtension.lowercased()) {
            guard file.lastPathComponent != shimsFile, let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let changed = change(text)
            if changed != text { try changed.write(to: file, atomically: true, encoding: .utf8) }
        }
    }

    private func saveIndex() {
        UserDefaults.standard.set(installed.map {
            ["id": $0.id, "enabled": $0.isEnabled, "deniedSites": $0.deniedSites.sorted()] as [String: Any]
        }, forKey: Self.indexKey)
    }

    /// Packages aren't signature-checked here, so only Mozilla's reviewed store is trusted to serve them.
    private static func packageURL(for input: String) async throws -> URL {
        if let url = URL(string: input), isStore(url), url.pathExtension.lowercased() == "xpi" { return url }
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
              let link = file["url"] as? String, let url = URL(string: link),
              isStore(url)
        else { throw InstallError.notFound }
        return url
    }

    private static func isStore(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host()?.lowercased() == "addons.mozilla.org"
    }

    enum InstallError: LocalizedError {
        case notFound
        var errorDescription: String? { String(localized: "No such add-on on addons.mozilla.org.") }
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
        // Its own pages can't load in a tab; they open in the add-on's sheet, which stands in as the tab.
        if let url = configuration.url, url.scheme == extensionContext.baseURL.scheme, url.host() == extensionContext.baseURL.host() {
            completionHandler(Self.showPage(url, of: extensionContext), nil)
            return
        }
        browser?.open(configuration.url, in: nil)
        completionHandler(browser?.selected, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let url = extensionContext.optionsPageURL { Self.showPage(url, of: extensionContext) }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popup = action.popupViewController, let top = Self.topViewController() else { completionHandler(nil); return }
        popup.modalPresentationStyle = .pageSheet
        top.present(popup, animated: true)
        completionHandler(nil)
    }
}

/// Shows only its add-on's pages. A link out opens in a tab, which shows the address and applies
/// HTTPS-only and the blocker; anything else is dropped.
private final class ExtensionPageController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let base: URL
    let webView: WKWebView
    weak var extensionTab: ExtensionPageTab?

    init(url: URL, base: URL, configuration: WKWebViewConfiguration) {
        self.base = base
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: url))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = webView }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let tab = extensionTab, navigationController?.isBeingDismissed ?? isBeingDismissed { ExtensionManager.shared.pageClosed(tab) }
    }

    /// `window.close()` from the page.
    func webViewDidClose(_ webView: WKWebView) { dismiss(animated: true) }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme == base.scheme, url.host() == base.host() { return .allow }
        // No target frame is a link to a new window, the usual kind on these pages.
        if action.targetFrame?.isMainFrame ?? true, action.navigationType == .linkActivated { leave(to: url) }
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { leave(to: url) }
        return nil
    }

    /// An add-on's own page is not a tab: no camera or microphone.
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }

    private func leave(to url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        dismiss(animated: true)
        ExtensionManager.shared.browser?.open(url, in: nil)
    }
}

/// The one browser window extensions see; private tabs stay out of it.
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    private unowned let manager: ExtensionManager

    init(manager: ExtensionManager) {
        self.manager = manager
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        (manager.browser?.tabs.filter { !$0.isPrivate } ?? []) + manager.pageTabs(of: context)
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        if let page = manager.pageTabs(of: context).last { return page }
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

    /// None for a tab not loaded yet: asking every tab made them all, and there is no page to script.
    func webView(for context: WKWebExtensionContext) -> WKWebView? { existingWebView }
    // The `tabs` permission shows every tab's address and title; a site the add-on is switched off on keeps both.
    func title(for context: WKWebExtensionContext) -> String? { isDenied(to: context) ? nil : title }
    func url(for context: WKWebExtensionContext) -> URL? { isDenied(to: context) ? nil : url }

    private func isDenied(to context: WKWebExtensionContext) -> Bool {
        url.map { context.permissionStatus(for: $0) == .deniedExplicitly } ?? false
    }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        ExtensionManager.shared.browser?.selectedID == id
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        load(url)
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        ExtensionManager.shared.browser?.select(self)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        ExtensionManager.shared.browser?.close(self)
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

/// An add-on page in its sheet, as a tab: Tampermonkey's install page gave up when `tabs.create`
/// returned none, and closing the tab closes the sheet.
final class ExtensionPageTab: NSObject, WKWebExtensionTab {
    fileprivate weak var page: ExtensionPageController?
    fileprivate weak var context: WKWebExtensionContext?

    fileprivate init(page: ExtensionPageController, context: WKWebExtensionContext) {
        self.page = page
        self.context = context
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { ExtensionManager.shared.focusedWindow }
    // Another add-on gets nothing from it.
    func webView(for context: WKWebExtensionContext) -> WKWebView? { context === self.context ? page?.webView : nil }
    func title(for context: WKWebExtensionContext) -> String? { context === self.context ? page?.webView.title : nil }
    func url(for context: WKWebExtensionContext) -> URL? { context === self.context ? page?.webView.url : nil }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(page?.webView.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { ExtensionManager.shared.pageTabs.last === self }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if context === self.context { page?.navigationController?.dismiss(animated: true) }
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { page?.webView.reloadFromOrigin() } else { page?.webView.reload() }
        completionHandler(nil)
    }
}
