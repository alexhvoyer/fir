import UIKit

/// The quick actions on the home screen icon, declared in project.yml. SwiftUI has no hook for them,
/// so a scene delegate catches each one.
enum QuickAction: String {
    case newTab = "NewTab"
    case newPrivateTab = "NewPrivateTab"

    @MainActor static let requests = PendingRequest<QuickAction>()

    @MainActor static func perform(_ item: UIApplicationShortcutItem) {
        if let action = QuickAction(rawValue: item.type) { requests.send(action) }
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
