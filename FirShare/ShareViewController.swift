import UIKit
import SwiftUI

/// Fir in the system share sheet: opens the shared link in Fir or sends it to another device.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(
            model: model,
            open: { [weak self] in self?.openInFir($0) },
            close: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        ))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        Task { await model.load(items) }
    }

    /// Share extensions get no call to open their app. The responder chain reaches the hosting window scene,
    /// which opens URLs as any scene does.
    private func openInFir(_ page: URL) {
        guard let url = OpenInFir.url(for: page) else { return }
        var responder: UIResponder? = self
        while let current = responder {
            if let scene = current as? UIScene {
                scene.open(url, options: nil)
                break
            }
            responder = current.next
        }
        extensionContext?.completeRequest(returningItems: nil)
    }
}
