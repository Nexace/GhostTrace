import AppKit
import RecorderCore

/// Turns NSWorkspace notifications into events. Needs no permission, but only sees what NSWorkspace posts to this
/// user session: regular apps (not every process execution), and sleep/wake without a wake reason.
public final class WorkspaceCollector: Collector, @unchecked Sendable {
    public struct Mapping: Sendable {
        let name: Notification.Name
        let event: @Sendable (Notification, RecorderClock) -> Event

        public init(_ name: Notification.Name, event: @escaping @Sendable (Notification, RecorderClock) -> Event) {
            self.name = name
            self.event = event
        }
    }

    public let id: String
    private let name: String
    private let mappings: [Mapping]
    private let center: NotificationCenter
    private let clock: RecorderClock
    private let lock = NSLock()
    private var tokens: [any NSObjectProtocol] = []
    private var lastEventAt: Date?

    public init(id: String, name: String, mappings: [Mapping],
                center: NotificationCenter = NSWorkspace.shared.notificationCenter, clock: RecorderClock = .live) {
        self.id = id
        self.name = name
        self.mappings = mappings
        self.center = center
        self.clock = clock
    }

    /// `observed` only once a notification has actually been delivered; registering an observer proves nothing.
    public func status() -> CapabilityStatus {
        let (listening, last) = lock.withLock { (!tokens.isEmpty, lastEventAt) }
        let (state, detail): (CapabilityState, String) = switch (listening, last) {
        case (false, _): (.unverified, "Not running.")
        case (true, nil): (.unverified, "Listening. No notification received yet, so delivery is not confirmed.")
        case (true, let last?): (.observed, "Listening. Last notification at \(GhostTraceJSON.string(from: last)).")
        }
        return CapabilityStatus(id: id, name: name, state: state, detail: detail)
    }

    public func start(emit: @escaping @Sendable (Event) -> Void) {
        lock.withLock {
            guard tokens.isEmpty else { return }
            let clock = clock
            tokens = mappings.map { mapping in
                // queue nil: delivered synchronously on the posting thread (NSWorkspace posts on the main thread).
                center.addObserver(forName: mapping.name, object: nil, queue: nil) { [weak self] note in
                    let event = mapping.event(note, clock)
                    self?.lock.withLock { self?.lastEventAt = event.recordedAt }
                    emit(event)
                }
            }
        }
    }

    public func stop() {
        lock.withLock {
            tokens.forEach(center.removeObserver)
            tokens = []
        }
    }
}

extension WorkspaceCollector {
    public static func appLifecycle(center: NotificationCenter = NSWorkspace.shared.notificationCenter, clock: RecorderClock = .live) -> WorkspaceCollector {
        WorkspaceCollector(id: "app-lifecycle", name: "App launch/quit (NSWorkspace)", mappings: [
            Mapping(NSWorkspace.didLaunchApplicationNotification) { appEvent(.appLaunch, $0, $1) },
            Mapping(NSWorkspace.didTerminateApplicationNotification) { appEvent(.appExit, $0, $1) },
        ], center: center, clock: clock)
    }

    public static func sleepWake(center: NotificationCenter = NSWorkspace.shared.notificationCenter, clock: RecorderClock = .live) -> WorkspaceCollector {
        let provenance = "Notification delivery time. Carries no wake reason; may not be posted for dark (maintenance) wakes (unverified)."
        return WorkspaceCollector(id: "sleep-wake", name: "Sleep/wake (NSWorkspace)", mappings: [
            Mapping(NSWorkspace.willSleepNotification) { note, clock in
                Event(kind: .sleep, source: "sleep-wake/\(note.name.rawValue)", provenance: provenance, clock: clock)
            },
            Mapping(NSWorkspace.didWakeNotification) { note, clock in
                Event(kind: .wake, source: "sleep-wake/\(note.name.rawValue)", provenance: provenance, clock: clock)
            },
        ], center: center, clock: clock)
    }

    static func appEvent(_ kind: EventKind, _ note: Notification, _ clock: RecorderClock) -> Event {
        let source = "app-lifecycle/\(note.name.rawValue)"
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return Event(kind: kind, source: source, provenance: "Notification carried no NSRunningApplication.", clock: clock)
        }
        let launchedAt = app.launchDate
        let useLaunchDate = kind == .appLaunch && launchedAt != nil
        return Event(kind: kind, source: source, occurredAt: useLaunchDate ? launchedAt : nil,
                     // processIdentifier is -1 when NSRunningApplication has no process to report.
                     subject: Subject(pid: app.processIdentifier > 0 ? app.processIdentifier : nil, bundleID: app.bundleIdentifier, name: app.localizedName,
                                      path: (app.bundleURL ?? app.executableURL)?.path, startedAt: launchedAt),
                     provenance: useLaunchDate ? "occurredAt from NSRunningApplication.launchDate." : "occurredAt is notification delivery time.",
                     clock: clock)
    }
}
