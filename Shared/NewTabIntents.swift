import AppIntents

/// What the controls ask for: true for a private tab.
enum NewTabRequest {
    @MainActor static let requests = PendingRequest<Bool>()
}

/// In both targets: the control names the intent, and the app runs it.
struct NewTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Tab"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        NewTabRequest.requests.send(false)
        return .result()
    }
}

struct NewPrivateTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Private Tab"
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        NewTabRequest.requests.send(true)
        return .result()
    }
}
