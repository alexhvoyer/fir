import UIKit

/// JavaScript alert, confirm and prompt as system alerts, titled with the page's host as Safari does.
@MainActor
enum PageDialog {
    /// Returns nil when cancelled, or when iOS drops or removes the alert: the page waits on the answer.
    static func present(_ message: String, host: String, cancel: String?, field: String? = nil,
                        confirm: String = "OK") async -> String? {
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

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

private final class DialogController: UIAlertController {
    var onDisappear: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}
