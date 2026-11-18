import UIKit
import UniformTypeIdentifiers
import MozillaAppServices

/// The shared link and the account's devices that take tabs.
@MainActor
@Observable
final class ShareModel {
    enum Devices {
        case loading, signedOut, failed
        case list([Device])
    }

    private(set) var page: URL?
    private(set) var title: String?
    /// The shared items were read; with no web link among them `page` stays nil.
    private(set) var loaded = false
    private(set) var devices = Devices.loading
    private(set) var sending: String?
    private(set) var sent: String?
    var sendFailed = false

    private var manager: FxAccountManager?
    private var observer: NSObjectProtocol?
    /// iOS may reuse the extension's process for the next share; the Rust components are set up once per process.
    private static var componentsReady = false

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func load(_ items: [NSExtensionItem]) async {
        (page, title) = await Self.link(in: items)
        loaded = true
        if page != nil { await connect() }
    }

    func send(to device: Device) async -> Bool {
        guard let page, sending == nil, let constellation = manager?.deviceConstellation() else { return false }
        sending = device.id
        defer { sending = nil }
        let ok = await withCheckedContinuation { continuation in
            constellation.sendEventToDevice(targetDeviceId: device.id,
                                            e: .sendTab(title: title ?? page.host() ?? "", url: page.absoluteString)) {
                if case .success = $0 { continuation.resume(returning: true) } else { continuation.resume(returning: false) }
            }
        }
        if ok { sent = device.id } else { sendFailed = true }
        return ok
    }

    /// The app's own sign-in, read from its keychain group. No polling for received tabs: those are the app's.
    private func connect() async {
        // As the app does at launch: the Rust components need NSS and their HTTP layer before any account call.
        if !Self.componentsReady {
            MozillaAppServices.initialize()
            Viaduct.shared.initialize(userAgent: "Fir-iOS-FxA/0.1")
            Self.componentsReady = true
        }
        let manager = FxAccountManager(
            config: FxAConfig(server: .release, clientId: MozillaAccount.clientID, redirectUri: MozillaAccount.redirectURI),
            // As the app names this iPhone; only used if the account had no device record yet.
            deviceConfig: DeviceConfig(name: String(localized: "Fir on \(UIDevice.current.name)"),
                                       deviceType: .mobile, capabilities: [.sendTab]),
            applicationScopes: [OAuthScope.profile, OAuthScope.oldSync, OAuthScope.session],
            keychainAccessGroup: Bundle.main.object(forInfoDictionaryKey: "FirKeychainGroup") as? String
        )
        let result = await withCheckedContinuation { continuation in
            manager.initialize { continuation.resume(returning: $0) }
        }
        self.manager = manager
        guard case .success = result else { devices = .failed; return }
        guard manager.hasAccount(), let constellation = manager.deviceConstellation() else { devices = .signedOut; return }
        observer = NotificationCenter.default.addObserver(forName: .constellationStateUpdate, object: nil, queue: .main) { [weak self] note in
            guard let state = note.userInfo?["newState"] as? ConstellationState else { return }
            MainActor.assumeIsolated { self?.devices = .list(Self.targets(state)) }
        }
        if let state = constellation.state() { devices = .list(Self.targets(state)) }
        constellation.refreshState()
        // No answer from the server: say so rather than spin while the sheet is open.
        try? await Task.sleep(for: .seconds(10))
        if case .loading = devices { devices = .failed }
    }

    private static func targets(_ state: ConstellationState) -> [Device] {
        state.remoteDevices.filter { $0.capabilities.contains(.sendTab) }
    }

    /// The first web link: Safari shares a URL, many apps share text with a link in it.
    private static func link(in items: [NSExtensionItem]) async -> (URL?, String?) {
        for item in items {
            // Safari puts the page title in the content text; some apps put the link itself there.
            let title = [item.attributedTitle?.string, item.attributedContentText?.string]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && firstLink(in: $0) == nil }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
                   OpenInFir.isWeb(url) {
                    return (url, title)
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                   let url = firstLink(in: text) {
                    return (url, title)
                }
            }
            if let text = item.attributedContentText?.string, let url = firstLink(in: text) { return (url, title) }
        }
        return (nil, nil)
    }

    private static func firstLink(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector?.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url).first(where: OpenInFir.isWeb)
    }
}
