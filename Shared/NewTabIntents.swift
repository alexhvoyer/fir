import AppIntents

/// What the controls ask for. They run in the app, where one that launched it waits for a handler.
enum NewTabRequest {
    @MainActor static var handler: ((_ isPrivate: Bool) -> Void)? {
        didSet { deliver() }
    }
    @MainActor private static var pending: Bool?

    @MainActor static func perform(isPrivate: Bool) {
        pending = isPrivate
        deliver()
    }

    @MainActor private static func deliver() {
        guard let handler, let isPrivate = pending else { return }
        pending = nil
        handler(isPrivate)
    }
}

/// In both targets: the control names the intent, and the app runs it.
struct NewTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Tab"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        NewTabRequest.perform(isPrivate: false)
        return .result()
    }
}

struct NewPrivateTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Private Tab"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        NewTabRequest.perform(isPrivate: true)
        return .result()
    }
}
