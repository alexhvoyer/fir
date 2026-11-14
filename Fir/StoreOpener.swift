import UIKit
import Synchronization

/// Opens a store on first use. A failed open, as while the phone is locked, is tried again once data
/// protection lifts or the app is next active, not on every access.
final class StoreOpener<Store>: @unchecked Sendable {
    private let open: () throws -> Store
    private let lock = NSLock()
    private var store: Store?
    /// Apart from the lock: the main thread clears it and mustn't wait out a slow open.
    private let failed = Atomic(false)
    private var observers: [NSObjectProtocol] = []

    init(_ open: @escaping () throws -> Store) {
        self.open = open
        let names = [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.failed.store(false, ordering: .relaxed)
            }
        }
    }

    var value: Store? {
        lock.withLock {
            if store == nil, !failed.load(ordering: .relaxed) {
                store = try? open()
                failed.store(store == nil, ordering: .relaxed)
            }
            return store
        }
    }
}
