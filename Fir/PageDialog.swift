import UIKit

/// JavaScript alert, confirm and prompt as system alerts, titled with the page's host as Safari does.
@MainActor
enum PageDialog {
    /// Returns nil when cancelled; otherwise the field's text, or "" without a field.
    static func present(_ message: String, host: String, cancel: String?, field: String? = nil,
                        confirm: String = "OK") async -> String? {
        guard let presenter = topViewController() else { return nil }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: host, message: message, preferredStyle: .alert)
            if let field { alert.addTextField { $0.text = field } }
            if let cancel {
                alert.addAction(UIAlertAction(title: cancel, style: .cancel) { _ in continuation.resume(returning: nil) })
            }
            alert.addAction(UIAlertAction(title: confirm, style: .default) { _ in
                continuation.resume(returning: alert.textFields?.first?.text ?? "")
            })
            presenter.present(alert, animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
