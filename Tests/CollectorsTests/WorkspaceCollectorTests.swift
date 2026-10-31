import AppKit
import Collectors
import RecorderCore
import Testing

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Event] = []
    var events: [Event] { lock.withLock { stored } }
    func add(_ event: Event) { lock.withLock { stored.append(event) } }
}

@Test func appLaunchNotificationBecomesAnEventWithProcessIdentity() throws {
    // The Dock always runs in a logged-in session, so it is a real NSRunningApplication with a pid.
    let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first)
    let center = NotificationCenter()
    let collector = WorkspaceCollector.appLifecycle(center: center)
    let received = Received()
    collector.start { received.add($0) }
    #expect(collector.status().state == .unverified)

    center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: dock])
    let event = try #require(received.events.first)
    #expect(event.kind == .appLaunch)
    #expect(event.subject?.pid == dock.processIdentifier)
    #expect(event.subject?.bundleID == "com.apple.dock")
    #expect(event.source == "app-lifecycle/NSWorkspaceDidLaunchApplicationNotification")
    #expect(collector.status().state == .observed)

    collector.stop()
    center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    #expect(received.events.count == 1)
}

@Test func notificationWithoutAnAppIsStillRecordedAndSaysSo() throws {
    let center = NotificationCenter()
    let collector = WorkspaceCollector.appLifecycle(center: center)
    let received = Received()
    collector.start { received.add($0) }
    center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    let event = try #require(received.events.first)
    #expect(event.kind == .appExit)
    #expect(event.subject == nil)
    #expect(event.provenance?.contains("no NSRunningApplication") == true)
}

@Test func invalidPidIsNotRecordedAsAProcessID() throws {
    let center = NotificationCenter()
    let collector = WorkspaceCollector.appLifecycle(center: center)
    let received = Received()
    collector.start { received.add($0) }
    // In a test runner (not an app), NSRunningApplication.current reports pid -1.
    center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
    let event = try #require(received.events.first)
    #expect(event.subject != nil)
    #expect(event.subject?.pid == nil || event.subject?.pid == getpid())
}

@Test func sleepAndWakeNotificationsBecomeEvents() {
    let center = NotificationCenter()
    let collector = WorkspaceCollector.sleepWake(center: center)
    let received = Received()
    collector.start { received.add($0) }
    center.post(name: NSWorkspace.willSleepNotification, object: nil)
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    #expect(received.events.map(\.kind) == [.sleep, .wake])
    #expect(received.events.allSatisfy { $0.provenance?.contains("no wake reason") == true })
}
