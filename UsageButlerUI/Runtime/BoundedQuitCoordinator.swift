import Foundation

/// One quit intent, including the asynchronous drain before AppKit terminate.
/// Scheduling is injected so a never-finishing drain is testable without sleep.
@MainActor public final class BoundedQuitCoordinator {
    private let schedule: (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    private let terminate: (Bool) -> Void
    private var requested = false, completed = false
    private var cancel: (@MainActor () -> Void)?
    public init(schedule: @escaping (@escaping @MainActor () -> Void) -> (@MainActor () -> Void), terminate: @escaping (Bool) -> Void) {
        self.schedule = schedule; self.terminate = terminate
    }
    public func request(drain: (@escaping @MainActor () -> Void) -> Void) {
        guard !requested else { return }; requested = true
        cancel = schedule { [weak self] in self?.finish(drained: false) }
        drain { [weak self] in self?.finish(drained: true) }
    }
    private func finish(drained: Bool) {
        guard !completed else { return }; completed = true
        cancel?(); cancel = nil; terminate(drained)
    }
}
