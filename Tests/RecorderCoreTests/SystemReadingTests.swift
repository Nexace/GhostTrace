import Foundation
@testable import RecorderCore
import Testing

@Test func counterDeltaHandlesResets() {
    #expect(Counter.delta(150, since: 100) == (50, false))
    #expect(Counter.delta(30, since: 100) == (30, true))
}

@Test func aSystemReadingRoundTripsThroughJSON() throws {
    let reading = SystemReading(
        at: Date(timeIntervalSince1970: 1_800_000_000.123),
        cpu: CPUTicks(busy: 10, total: 40), network: NetworkBytes(received: 5, sent: 6), disk: DiskBytes(read: 7, written: 8),
        gpuUtilization: 12, gpuMemoryInUse: 1 << 20, memoryUsed: 9 << 30, memoryTotal: 16 << 30, pressure: .warn,
        freeSpace: 100 << 30, volumeCapacity: 500 << 30,
        battery: BatteryReading(onBattery: true, charging: false, charge: 80, watts: 6.5, minutesToEmpty: 300), idleSeconds: 42.5)
    let data = try GhostTraceJSON.encoder().encode(reading)
    #expect(try GhostTraceJSON.decoder().decode(SystemReading.self, from: data) == reading)
}
