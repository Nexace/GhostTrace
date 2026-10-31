import RecorderCore
import Testing

@Test func grantedCollectorStartsAndStops() async throws {
    let collector = MockCollector(permissionGranted: true)
    try await collector.start { _ in }
    #expect(await collector.isRunning)
    #expect(await collector.status().state == .observed)
    await collector.stop()
    #expect(await !collector.isRunning)
}

@Test func collectorWithoutPermissionRefusesToStartAndReportsMissing() async {
    let collector = MockCollector(permissionGranted: false)
    await #expect(throws: CollectorError.permissionMissing("mock")) { try await collector.start { _ in } }
    #expect(await !collector.isRunning)
    #expect(await collector.status().state == .missing)
}
