/// A request from outside the views. One that launched the app waits until a handler is set.
@MainActor
final class PendingRequest<Value> {
    private var pending: Value?

    var handler: ((Value) -> Void)? {
        didSet { deliver() }
    }

    func send(_ value: Value) {
        pending = value
        deliver()
    }

    private func deliver() {
        guard let handler, let value = pending else { return }
        pending = nil
        handler(value)
    }
}
