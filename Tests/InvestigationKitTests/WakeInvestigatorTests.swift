import Collectors
import Foundation
import InvestigationKit
import RecorderCore
import Testing

private let clock = RecorderClock(now: { Date(milliseconds: 1_793_100_000_000) }, bootSessionID: "boot-now")
private let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
private func utc(_ text: String) -> Date { try! iso.parse(text) }

// Lines copied from `pmset -g log` on macOS 27.0.1 (type column padded with spaces, then a tab).
private let timerWakeLog = """
    2026-10-27 17:02:38 +0530 Sleep               \tEntering Sleep state due to 'Sleep Service Back to Sleep':TCPKeepAlive=active Using AC (Charge:85%) 529 secs
    2026-10-27 17:02:38 +0530 Wake Requests       \t[process=dasd request=SleepService deltaSecs=942 wakeAt=2026-10-27 17:18:20 info="com.apple.dasd:0:com.apple.MobileAccessoryUpdater.deviceIdleCheck"] [process=mDNSResponder request=Maintenance deltaSecs=7200 wakeAt=2026-10-27 19:02:38 info="upkeep wake"] [*process=powerd request=CSPNEvaluation deltaSecs=529 wakeAt=2026-10-27 17:11:27]
    2026-10-27 17:02:38 +0530 PM Client Acks      \tDelays to Sleep notifications: [AirPort configd plug-in is slow(495 ms)]
    2026-10-27 17:11:27 +0530 DarkWake            \tDarkWake from Deep Idle [CDNPB] : due to NUB.SPMI0.SW3 nub-spmi0.0x02 rtc/Maintenance Using AC (Charge:85%) 25 secs
    2026-10-27 17:11:27 +0530 WakeDetails         \tDriverReason:NUB.SPMI0.SW3 - DriverDetails:
    """

private let keyboardWakeLog = """
    2026-10-27 19:13:19 +0530 Sleep               \tEntering Sleep state due to 'Software Sleep pid=418':TCPKeepAlive=active Using Batt (Charge:83%) 65 secs
    2026-10-27 19:14:24 +0530 Wake                \tWake from Deep Idle [CDNVA] : due to MTP.DOCK.CHANNELS.AP0.IRQ RTP.keyboard/UserActivity Assertion Using BATT (Charge:83%)
    """

private func started(_ at: String) -> Event {
    Event(kind: .collectorStatus, source: "recorder", occurredAt: utc(at), payload: ["state": "recorder_started"], clock: clock)
}

private func launch(_ name: String, at: String) -> Event {
    Event(kind: .appLaunch, source: "app-lifecycle/NSWorkspaceDidLaunchApplicationNotification", occurredAt: utc(at),
          subject: Subject(pid: 501, bundleID: "com.example.\(name.lowercased())", name: name), clock: clock)
}

private func wakeNote(at: String) -> Event {
    Event(kind: .wake, source: "sleep-wake/NSWorkspaceDidWakeNotification", occurredAt: utc(at), clock: clock)
}

private let fullCoverage = Coverage(recordingSince: utc("2026-10-27T10:00:00.000Z"), powerLogSince: utc("2026-10-20T14:06:21.000Z"),
                                    powerLogThrough: utc("2026-10-27T14:00:00.000Z"), powerLogError: nil)

private func investigate(_ events: [Event], from: String, to: String, coverage: Coverage = fullCoverage) -> WakeInvestigation {
    WakeInvestigator.investigate(from: utc(from), to: utc(to), events: events.sorted { $0.occurredAt < $1.occurredAt }, coverage: coverage)
}

private let order: [Confidence] = [.observed, .likely, .unknown, .correlated]

// MARK: Parser

@Test func powerLogLinesBecomeImportedDiagnosticsInUTC() throws {
    let snapshot = PowerLog.parse(timerWakeLog, clock: clock)
    #expect(snapshot.coversFrom == utc("2026-10-27T11:32:38.000Z"))
    #expect(snapshot.events.map { $0.payload["entry"] } == ["sleep", "wake_request", "wake_request", "wake_request", "dark_wake"])
    #expect(snapshot.events.allSatisfy { $0.kind == .diagnostic && $0.quality == .imported && $0.bootSessionID == nil && $0.monotonicNanos == nil })

    let sleep = snapshot.events[0]
    #expect(sleep.payload["reason"] == "Sleep Service Back to Sleep")
    let wake = snapshot.events[4]
    #expect(wake.occurredAt == utc("2026-10-27T11:41:27.000Z"))
    #expect(wake.payload["reason"] == "NUB.SPMI0.SW3 nub-spmi0.0x02 rtc/Maintenance")
    #expect(wake.provenance?.hasPrefix("2026-10-27 17:11:27 +0530 DarkWake") == true)

    let marked = try #require(snapshot.events.first { $0.payload["marked"] == "true" })
    #expect(marked.payload["process"] == "powerd")
    #expect(marked.payload["request"] == "CSPNEvaluation")
    // From deltaSecs (529 s after the sleep line), not from the zone-less wakeAt text.
    #expect(marked.payload["wake_at"] == "2026-10-27T11:41:27.000Z")
    #expect(snapshot.events[2].payload["info"] == "upkeep wake")
}

@Test func reimportingTheSameLogGivesTheSameIDs() {
    let later = RecorderClock(now: { Date(milliseconds: 1_800_000_000_000) }, bootSessionID: "boot-later")
    let first = PowerLog.parse(timerWakeLog, clock: clock).events.map(\.id)
    #expect(first == PowerLog.parse(timerWakeLog, clock: later).events.map(\.id))
    #expect(Set(first).count == first.count)
}

@Test func lineOffsetsAreHonouredAndOtherLinesIgnored() {
    let text = """
        Sleep/Wakes since boot at 2026-10-20 19:30:00 +0530 :1
        2026-11-01 01:30:00 -0700 Wake                \tWake from Deep Idle [CDNVA] : due to lid Using AC (Charge:90%)
        2026-11-01 01:30:00 -0800 Wake                \tWake from Deep Idle [CDNVA] : due to lid Using AC (Charge:90%)
        2026-11-01 01:31:00 -0800 Assertions          \tPID 1(launchd) Created PreventUserIdleSystemSleep
        """
    let events = PowerLog.parse(text, clock: clock).events
    // The same wall-clock time either side of a DST change is two different instants.
    #expect(events.map(\.occurredAt) == [utc("2026-11-01T08:30:00.000Z"), utc("2026-11-01T09:30:00.000Z")])
}

// MARK: Scenarios

@Test func timerWakeWithMisleadingAppLaunchKeepsTheLaunchAsACorrelate() throws {
    let log = PowerLog.parse(timerWakeLog, clock: clock).events
    let mail = launch("Mail", at: "2026-10-27T11:41:28.500Z")
    let result = investigate(log + [started("2026-10-27T10:00:00.000Z"), mail], from: "2026-10-27T11:30:00.000Z", to: "2026-10-27T12:00:00.000Z")

    let wake = try #require(result.wakes.first)
    #expect(result.wakes.count == 1)
    #expect(wake.type == .dark)
    #expect(wake.at == utc("2026-10-27T11:41:27.000Z"))
    #expect(wake.summary == "Likely cause: a timer set by powerd (CSPNEvaluation).")

    let darkWake = try #require(log.first { $0.payload["entry"] == "dark_wake" })
    #expect(wake.findings[0].confidence == .observed)
    #expect(wake.findings[0].evidence == [darkWake.id])
    #expect(wake.findings[0].statement.contains("rtc/Maintenance"))

    let request = try #require(log.first { $0.payload["request"] == "CSPNEvaluation" })
    let scheduled = try #require(wake.findings.first { $0.evidence.contains(request.id) })
    #expect(scheduled.confidence == .likely)
    #expect(scheduled.statement.hasPrefix("powerd had requested a wake"))
    #expect(wake.findings.contains { $0.confidence == .likely && $0.statement == "A scheduled wake timer fired." })

    let mailFinding = try #require(wake.findings.first { $0.evidence == [mail.id] })
    #expect(mailFinding.confidence == .correlated)
    #expect(!mailFinding.statement.contains("caus"))
    #expect(mailFinding.basis.contains("can't show that it caused"))
    // Ranked: nothing correlated before anything observed or likely.
    #expect(wake.findings.map { order.firstIndex(of: $0.confidence)! } == wake.findings.map { order.firstIndex(of: $0.confidence)! }.sorted())

    #expect(wake.limits.map(\.statement) == ["macOS posted no wake notification. Dark wakes keep the display off, and macOS may not post one for them."])
    #expect(Set(result.evidence.map(\.id)) == [darkWake.id, request.id, mail.id])
    #expect(result.limits.isEmpty)
}

@Test func keyboardWakePairsTheNotificationAndDoesNotPromoteTheNextApp() throws {
    let log = PowerLog.parse(keyboardWakeLog, clock: clock).events
    let note = wakeNote(at: "2026-10-27T13:44:24.552Z")
    let calendar = launch("Calendar", at: "2026-10-27T13:44:26.000Z")
    let result = investigate(log + [started("2026-10-27T10:00:00.000Z"), note, calendar],
                             from: "2026-10-27T13:30:00.000Z", to: "2026-10-27T14:00:00.000Z")

    let wake = try #require(result.wakes.first)
    #expect(result.wakes.count == 1)
    #expect(wake.type == .full)
    #expect(wake.summary == "Likely cause: keyboard or trackpad input.")
    #expect(wake.findings[0].confidence == .observed)
    #expect(wake.findings[0].evidence.contains(note.id))
    #expect(wake.findings[0].statement.hasSuffix("macOS posted a wake notification less than a second later."))
    #expect(wake.findings.filter { $0.confidence == .likely }.map(\.statement) == ["Keyboard, trackpad or other input from the user."])
    #expect(wake.findings.last?.confidence == .correlated)
    #expect(wake.findings.last?.evidence == [calendar.id])
    #expect(wake.limits.isEmpty)
}

@Test func withoutThePowerLogTheReasonIsUnknownAndNothingIsLikely() throws {
    let note = wakeNote(at: "2026-10-27T13:44:24.552Z")
    let calendar = launch("Calendar", at: "2026-10-27T13:44:26.000Z")
    let noLog = Coverage(recordingSince: utc("2026-10-27T10:00:00.000Z"), powerLogSince: nil, powerLogThrough: nil, powerLogError: "pmset -g log exited with status 1")
    let result = investigate([started("2026-10-27T10:00:00.000Z"), note, calendar],
                             from: "2026-10-27T13:30:00.000Z", to: "2026-10-27T14:00:00.000Z", coverage: noLog)

    let wake = try #require(result.wakes.first)
    #expect(wake.type == .unknown)
    #expect(wake.summary == "Cause unknown: the power log has no entry for this wake.")
    #expect(wake.findings.map(\.confidence) == [.observed, .unknown, .correlated])
    #expect(wake.findings[1].basis == "The imported power log doesn't cover this time.")
    #expect(result.limits.map(\.statement) == [
        "The power log wasn't read for this investigation (pmset -g log exited with status 1). Only entries imported earlier are used.",
        "No power log entries have been imported, so no wake reason can be checked.",
    ])
}

@Test func notificationPairsWithTheNearerDarkToFullWake() throws {
    let text = """
        2026-10-27 17:42:22 +0530 DarkWake            \tDarkWake from Deep Idle [CDNPB] : due to smc.sysState.Wake(0x70070000) USB-C_plug SMC.OutboxNotEmpty nub-spmi-a0.0x3F/ Using AC (Charge:85%) 13 secs
        2026-10-27 17:42:27 +0530 DarkWake            \tDarkWake to FullWake from Deep Idle [CDNVA] : due to Notification Using AC (Charge:85%)
        """
    let log = PowerLog.parse(text, clock: clock).events
    let note = wakeNote(at: "2026-10-27T12:12:27.300Z")
    let result = investigate(log + [started("2026-10-27T10:00:00.000Z"), note], from: "2026-10-27T12:00:00.000Z", to: "2026-10-27T12:30:00.000Z")

    #expect(result.wakes.map(\.type) == [.dark, .darkToFull])
    #expect(!result.wakes[0].findings[0].evidence.contains(note.id))
    #expect(result.wakes[1].findings[0].evidence.contains(note.id))
    #expect(result.wakes[0].findings.contains { $0.statement == "Something was plugged into a USB-C port, such as a charger." })
    #expect(result.wakes[1].findings.contains { $0.statement == "A notification needed the display." })
}

@Test func timerWakeWithNoDueRequestIsAnOpenQuestion() throws {
    let text = """
        2026-10-27 17:02:38 +0530 Wake Requests       \t[process=dasd request=SleepService deltaSecs=942 wakeAt=2026-10-27 17:18:20]
        2026-10-27 17:11:27 +0530 DarkWake            \tDarkWake from Deep Idle [CDNPB] : due to NUB.SPMI0.SW3 nub-spmi0.0x02 rtc/Maintenance Using AC (Charge:85%) 25 secs
        """
    let result = investigate(PowerLog.parse(text, clock: clock).events + [started("2026-10-27T10:00:00.000Z")],
                             from: "2026-10-27T11:30:00.000Z", to: "2026-10-27T12:00:00.000Z")
    let open = try #require(result.wakes.first?.findings.first { $0.confidence == .unknown })
    #expect(open.statement == "A timer (Maintenance) woke the Mac, but none of the 1 wake requests logged at the previous sleep was due at this time.")
    #expect(result.wakes.first?.findings.contains { $0.statement.contains("had requested") } == false)
    #expect(result.wakes.first?.summary == "Likely cause: a scheduled timer (what set it is unknown).")
}

@Test func wakeDuringARecorderGapCitesTheGap() throws {
    let log = PowerLog.parse(keyboardWakeLog, clock: clock).events
    let gap = Event.gap(from: utc("2026-10-27T13:00:00.000Z"), to: utc("2026-10-27T13:50:00.000Z"), reason: .recorderStopped, clock: clock)
    let result = investigate(log + [started("2026-10-27T10:00:00.000Z"), gap], from: "2026-10-27T13:30:00.000Z", to: "2026-10-27T14:00:00.000Z")

    let wake = try #require(result.wakes.first)
    #expect(wake.limits.map(\.evidence) == [[gap.id]])
    #expect(wake.limits[0].statement.contains("recorder_stopped"))
    #expect(result.evidence.contains { $0.id == gap.id })
}

@Test func wakeBeforeTheRecorderFirstRanIsCoveredOnlyByThePowerLog() throws {
    let log = PowerLog.parse(keyboardWakeLog, clock: clock).events
    let late = Coverage(recordingSince: utc("2026-10-27T13:50:00.000Z"), powerLogSince: fullCoverage.powerLogSince,
                        powerLogThrough: fullCoverage.powerLogThrough, powerLogError: nil)
    let result = investigate(log + [started("2026-10-27T13:50:00.000Z")], from: "2026-10-27T13:30:00.000Z", to: "2026-10-27T14:00:00.000Z", coverage: late)
    #expect(result.wakes.first?.limits.map(\.statement) == ["GhostTrace wasn't recording yet, so only the power log covers this wake."])
    #expect(result.limits.map(\.statement) == ["GhostTrace started recording after this window begins. Wake notifications and app launches before that weren't recorded."])
}

@Test func emptyWindowReportsNoWakesAndItsCoverage() {
    let result = investigate([started("2026-10-27T10:00:00.000Z")], from: "2026-10-27T11:00:00.000Z", to: "2026-10-27T11:30:00.000Z")
    #expect(result.wakes.isEmpty)
    #expect(result.evidence.isEmpty)
    #expect(result.limits.isEmpty)
}

@Test func parsingSinceSkipsStoredLinesButKeepsTheLogStart() throws {
    let since = utc("2026-10-27T11:35:00.000Z") // 17:05 +0530: after the sleep, before the dark wake.
    let snapshot = PowerLog.parse(timerWakeLog, since: since, clock: clock)
    #expect(snapshot.events.map { $0.payload["entry"] } == ["dark_wake"])
    #expect(snapshot.coversFrom == utc("2026-10-27T11:32:38.000Z"))
}
