/// A source of events.
public protocol Collector: Sendable {
    var id: String { get }
    func status() async -> CapabilityStatus
    /// Must throw rather than start in a degraded state that looks like success.
    func start(emit: @escaping @Sendable (Event) -> Void) async throws
    func stop() async
}

public enum CollectorError: Error, Equatable, Sendable {
    case permissionMissing(String)
    case commandFailed(String)
}
