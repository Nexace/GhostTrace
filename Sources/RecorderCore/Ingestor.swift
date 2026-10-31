import Foundation

public enum GapReason: String, Sendable {
    case recorderStopped = "recorder_stopped"
    case recorderInterrupted = "recorder_interrupted"
    case queueOverflow = "queue_overflow"
    case paused
    /// FSEvents said it dropped events for a watched folder, or GhostTrace's rate limit did.
    case watchDropped = "watch_dropped"
    /// The power log rolled over between two imports, so its entries in between were never read.
    case powerLogHole = "power_log_hole"
    /// The user turned "Record System Activity" off: no CPU, GPU, network, disk or battery readings in this span.
    case systemMonitorOff = "system_monitor_off"
}

extension Event {
    /// A span in which events were not recorded.
    public static func gap(from: Date, to: Date, reason: GapReason, detail: [String: String] = [:], provenance: String? = nil,
                           clock: RecorderClock) -> Event {
        Event(kind: .eventGap, source: "recorder", occurredAt: from, endedAt: to,
              payload: detail.merging(["reason": reason.rawValue]) { _, new in new },
              quality: .inferred, provenance: provenance, clock: clock)
    }

    /// The gap since the previous recorder run ended. Nil on the first run, which promised no earlier coverage.
    public static func startupGap(lastAlive: Date?, cleanStop: Bool, lastBootSessionID: String?, clock: RecorderClock) -> Event? {
        guard let lastAlive else { return nil }
        let bootChanged = switch (lastBootSessionID, clock.bootSessionID) {
        case let (last?, current?): String(last != current)
        default: "unknown"
        }
        return gap(from: lastAlive, to: clock.now(), reason: cleanStop ? .recorderStopped : .recorderInterrupted,
                   detail: ["boot_changed": bootChanged],
                   provenance: cleanStop ? "Previous run stopped cleanly at the gap start."
                       : "Previous run ended without a clean stop; the gap starts at its last heartbeat (written every 5 min).",
                   clock: clock)
    }
}

/// Bounded buffer between collectors and the single store writer.
/// Overflow drops events, and the next flush records an `event_gap` with the count.
/// `whenBuffered` asks the owner for a flush when events arrive, so an idle recorder never wakes up to flush.
public final class Ingestor: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private let clock: RecorderClock
    private let write: @Sendable ([Event]) throws -> Void
    private let whenBuffered: @Sendable (Ingestor) -> Void
    /// A flush has been asked for and hasn't completed yet.
    private var flushPending = false
    private var buffer: [Event] = []
    private var dropped = 0
    private var droppedSince: Date?
    private var droppedTotal = 0
    private var paused = false

    /// `whenBuffered` is called once per batch, outside the lock; the owner should call `flush()` soon after.
    public init(capacity: Int = 10_000, clock: RecorderClock, write: @escaping @Sendable ([Event]) throws -> Void,
                whenBuffered: @escaping @Sendable (Ingestor) -> Void = { _ in }) {
        self.capacity = capacity
        self.clock = clock
        self.write = write
        self.whenBuffered = whenBuffered
    }

    /// While paused, collector events are discarded; the recorder records the paused span as a gap itself.
    public var isPaused: Bool {
        get { lock.withLock { paused } }
        set { lock.withLock { paused = newValue } }
    }

    public var droppedCount: Int { lock.withLock { droppedTotal } }

    /// `whilePaused` is for the recorder's own markers (pause, stop), which must be kept.
    public func submit(_ event: Event, whilePaused: Bool = false) {
        let askForFlush: Bool = lock.withLock {
            guard !paused || whilePaused else { return false }
            if buffer.count < capacity {
                buffer.append(event)
            } else {
                if dropped == 0 { droppedSince = event.occurredAt }
                dropped += 1
                droppedTotal += 1
            }
            defer { flushPending = true }
            return !flushPending
        }
        if askForFlush { whenBuffered(self) }
    }

    /// Writes everything buffered as one batch. On failure the events stay buffered (still bounded) and the flush is
    /// still pending: the caller retries. Call from one queue only.
    @discardableResult
    public func flush() throws -> Int {
        // The overflow gap rides along with the batch instead of taking buffer space; a failed write rebuilds it next time.
        let (batch, buffered, droppedNow): ([Event], Int, Int) = lock.withLock {
            var batch = buffer
            if dropped > 0, let since = droppedSince {
                batch.append(.gap(from: since, to: clock.now(), reason: .queueOverflow, detail: ["dropped_count": String(dropped)],
                                  provenance: "Ingestion queue was full (capacity \(capacity)).", clock: clock))
            }
            return (batch, buffer.count, dropped)
        }
        guard !batch.isEmpty else {
            lock.withLock { flushPending = false }
            return 0
        }
        try write(batch)
        // Events that arrived during the write need another flush.
        let askAgain: Bool = lock.withLock {
            buffer.removeFirst(buffered)
            dropped -= droppedNow
            if dropped == 0 { droppedSince = nil }
            flushPending = !buffer.isEmpty || dropped > 0
            return flushPending
        }
        if askAgain { whenBuffered(self) }
        return batch.count
    }
}
