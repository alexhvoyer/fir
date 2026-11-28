import UIKit
import WebKit

/// JavaScript alert, confirm and prompt as system alerts, titled with the page's host as Safari does.
@MainActor
enum PageDialog {
    /// Returns nil when cancelled, or when iOS drops or removes the alert: the page waits on the answer.
    static func present(_ message: String, host: String, cancel: String?, field: String? = nil,
                        confirm: String = String(localized: "OK")) async -> String? {
        guard let presenter = topViewController() else { return nil }
        return await withCheckedContinuation { continuation in
            var answered = false
            let answer: (String?) -> Void = { result in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: result)
            }
            let alert = DialogController(title: host, message: message, preferredStyle: .alert)
            if let field { alert.addTextField { $0.text = field } }
            if let cancel {
                alert.addAction(UIAlertAction(title: cancel, style: .cancel) { _ in answer(nil) })
            }
            alert.addAction(UIAlertAction(title: confirm, style: .default) { [weak alert] _ in
                answer(alert?.textFields?.first?.text ?? "")
            })
            // A turn later, so a tapped button's handler answers first.
            alert.onDisappear = { DispatchQueue.main.async { answer(nil) } }
            presenter.present(alert, animated: true)
            if alert.presentingViewController == nil { answer(nil) }
        }
    }

    fileprivate static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

/// The system share sheet for a page.
@MainActor
enum PageShare {
    /// The web view makes iOS offer Add to Home Screen. Never for private tabs, and not while loading
    /// another site: the icon could take the shown page's look and the loading address.
    static func present(_ url: URL, of tab: BrowserTab) {
        let page = !tab.isPrivate && BrowserTab.sameOrigin(tab.webView.url, tab.pageURL)
        let link = SharedLink(url: url, isPrivate: tab.isPrivate)
        let items: [Any] = page ? [link, tab.webView] : [link]
        guard let top = PageDialog.topViewController() else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.anchorPopover(centredIn: top)
        top.present(sheet, animated: true)
    }

    /// Closes an open share sheet, which would keep showing a private page above its lock.
    static func dismiss() {
        if let sheet = PageDialog.topViewController() as? UIActivityViewController {
            sheet.dismiss(animated: false)
        }
    }
}

/// A tab's address for the share sheet. Fir's own extension gets none from a private tab: it would carry the
/// link into a regular tab or to another device. iOS lists that extension here regardless of exclusions.
private final class SharedLink: NSObject, UIActivityItemSource {
    let url: URL
    let isPrivate: Bool

    init(url: URL, isPrivate: Bool) {
        self.url = url
        self.isPrivate = isPrivate
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        return isPrivate && type?.rawValue == "dev.khvoynitsky.browser.Share" ? nil : url
    }
}

private final class DialogController: UIAlertController {
    var onDisappear: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}

extension UIViewController {
    /// On iPad a share sheet or add-on popup is a popover, and one with no anchor crashed the app: centred, without an arrow.
    func anchorPopover(centredIn presenter: UIViewController) {
        guard let popover = popoverPresentationController else { return }
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
    }
}
