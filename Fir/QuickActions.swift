import UIKit

/// The quick actions on the home screen icon, declared in project.yml. SwiftUI has no hook for them,
/// so a scene delegate catches each one; one that launched the app waits until a handler is set.
enum QuickAction: String {
    case newTab = "NewTab"
    case newPrivateTab = "NewPrivateTab"

    @MainActor static var handler: ((QuickAction) -> Void)? {
        didSet { deliver() }
    }
    @MainActor private static var pending: QuickAction?

    @MainActor static func perform(_ item: UIApplicationShortcutItem) {
        guard let action = QuickAction(rawValue: item.type) else { return }
        pending = action
        deliver()
    }

    @MainActor private static func deliver() {
        guard let handler, let action = pending else { return }
        pending = nil
        handler(action)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // A cold launch from a quick action brings it here rather than to the scene delegate.
        if let item = options.shortcutItem { QuickAction.perform(item) }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        QuickAction.perform(shortcutItem)
        return true
    }
}
