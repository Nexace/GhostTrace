import RecorderCore

/// Deterministic collector for tests.
/// shortcut: lives in this test target only; move to a shared test-support target when a second test target needs it.
actor MockCollector: Collector {
    nonisolated let id: String
    private let permissionGranted: Bool
    private(set) var isRunning = false

    init(id: String = "mock", permissionGranted: Bool) {
        self.id = id
        self.permissionGranted = permissionGranted
    }

    func status() -> CapabilityStatus {
        CapabilityStatus(id: id, name: "Mock collector",
                         state: permissionGranted ? .observed : .missing,
                         detail: permissionGranted ? "Running in tests." : "Permission not granted.")
    }

    func start(emit: @escaping @Sendable (Event) -> Void) throws {
        guard permissionGranted else { throw CollectorError.permissionMissing(id) }
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}
