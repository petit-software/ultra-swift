import Foundation

/// Holds notification observers so they are torn down by a NONISOLATED deinit.
///
/// A main-actor `deinit` cannot touch main-actor state, so a view that stores its own
/// observer token cannot remove it on the way out — the compiler rejects the access. A box
/// can: it is an ordinary class with no isolation, so its `deinit` is free to run anywhere,
/// and dropping the box is what removes the observers.
///
/// `@unchecked Sendable` covers the tokens, which Foundation does not annotate; nothing here
/// is mutated after the box is handed to the view that owns it except by that view.
public final class ObserverBox: @unchecked Sendable {
    public var tokens: [NSObjectProtocol] = []

    public init() {}

    public func add(_ token: NSObjectProtocol) { tokens.append(token) }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
