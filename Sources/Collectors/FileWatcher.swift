import CoreServices
import Foundation
import RecorderCore

/// Records changes under user-selected paths with FSEvents. FSEvents says *that* a path changed, never *which process*
/// changed it, so these events carry no writer. Needs no permission for ordinary folders (TCC-protected ones: unverified).
public final class FileWatcher: Collector, @unchecked Sendable {
    public static let maxPaths = 32
    static let latency: CFTimeInterval = 1
    /// Beyond this, changes are dropped and the drop is recorded as an `event_gap` (bounds a busy build folder).
    static let maxEventsPerSecond = 200
    static let provenance = "Delivered by FSEvents up to about 1 s after the change; occurredAt is delivery time. FSEvents doesn't say which process made the change, and its flags can include earlier changes to the same item."
    static let historyProvenance = "Read back from FSEvents' history when the recorder started again: the item changed at some point in this interval, while GhostTrace wasn't running. The history keeps which items changed, not when or how often, and not which process changed them."
    /// A replay lists at most this many items; the rest are counted in a `watch_dropped` gap.
    static let maxReplayedPaths = 1000

    public let id = "file-watch"
    private let excluding: String
    private let clock: RecorderClock
    /// All state below is touched only on this queue, where FSEvents also delivers.
    private let queue = DispatchQueue(label: "ghosttrace.fsevents", qos: .utility)
    private var paths: [String] = []
    private var stream: FSEventStreamRef?
    private var emit: (@Sendable (Event) -> Void)?
    private var failure: String?
    private var lastEventAt: Date?
    private var lastDeliveryAt: Date?
    private var second: Int64 = 0
    private var inSecond = 0
    private var dropped = 0
    private var droppedSince: Date?
    /// FSEvents ids: the system's latest when the stream started, and the highest delivered since.
    private var startID: FSEventStreamEventId = 0
    private var lastID: FSEventStreamEventId = 0
    /// Asked for by `replayChanges`, used by the next stream start.
    private var replay: (since: FSEventStreamEventId, from: Date)?
    /// A replay in progress: history items are merged per path until FSEvents says the history is done.
    private var history: (since: FSEventStreamEventId, from: Date, to: Date, flags: [String: FSEventStreamEventFlags], lost: Bool)?

    /// Changes at or under `excluding` (GhostTrace's own data folder) are never reported, so the database can't feed itself.
    public init(excluding: String, clock: RecorderClock = .live) {
        self.excluding = Self.canonicalPath(excluding)
        self.clock = clock
    }

    public func status() -> CapabilityStatus {
        queue.sync {
            let name = "Watched folders (FSEvents)"
            let (state, detail): (CapabilityState, String) = switch (failure, paths.isEmpty, stream != nil, lastEventAt) {
            case let (failure?, _, _, _): (.missing, failure)
            case (nil, true, _, _): (.unverified, "Not watching anything. Add a folder with: ghosttrace watch add PATH")
            case (nil, false, false, _): (.unverified, "Not running.")
            case (nil, false, true, nil): (.unverified, "Watching \(paths.count) path\(paths.count == 1 ? "" : "s"). No change seen yet, so delivery isn't confirmed.")
            case let (nil, false, true, last?): (.observed, "Watching \(paths.count) path\(paths.count == 1 ? "" : "s"). Last change at \(GhostTraceJSON.string(from: last)).")
            }
            return CapabilityStatus(id: id, name: name, state: state, detail: detail)
        }
    }

    /// Canonical paths (see `canonicalPath`). Replaces the watched set; restarts the stream if running.
    public func setPaths(_ paths: [String]) {
        queue.sync {
            self.paths = paths
            if emit != nil { restartStream() }
        }
    }

    public func start(emit: @escaping @Sendable (Event) -> Void) {
        queue.sync {
            self.emit = emit
            restartStream()
        }
    }

    public func stop() {
        queue.sync {
            flushDropped(now: clock.now())
            stopStream()
            // An unfinished replay is dropped; `checkpoint` still pointed before it, so the next start replays it again.
            history = nil
            emit = nil
        }
    }

    /// FSEvents ids persist across restarts and reboots. Every change after this one has been delivered (or is being
    /// replayed), so a later `replayChanges(since:)` from it misses nothing. Nil while no stream runs.
    public var checkpoint: UInt64? {
        queue.sync {
            guard stream != nil else { return nil }
            return history?.since ?? max(startID, lastID)
        }
    }

    /// The next stream start reads FSEvents' history after `since` (a saved `checkpoint`) and records each changed item
    /// once, as an interval event from `from` to the start. Call before `start`.
    public func replayChanges(since: UInt64, from: Date) {
        queue.sync { replay = (since, from) }
    }

    private func restartStream() {
        // A replay cut short by a path change is asked for again, so its history isn't lost.
        if let history { replay = (history.since, history.from) }
        history = nil
        stopStream()
        failure = nil
        guard !paths.isEmpty else {
            replay = nil
            return
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info!).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.deliver((0..<min(count, paths.count)).map { (paths[$0], flags[$0], ids[$0]) })
        }
        // WatchRoot: report when a watched path itself is moved or deleted.
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
        (startID, lastID) = (FSEventsGetCurrentEventId(), 0)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, replay?.since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               Self.latency, FSEventStreamCreateFlags(flags)) else {
            failure = "FSEventStreamCreate failed."
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            failure = "FSEventStreamStart failed."
            return
        }
        self.stream = stream
        lastDeliveryAt = clock.now()
        if let replay { history = (replay.since, replay.from, lastDeliveryAt!, [:], false) }
        replay = nil
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func deliver(_ batch: [(path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId)]) {
        guard let emit else { return }
        let now = clock.now()
        let lostFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        for item in batch {
            if history != nil {
                if item.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
                    finishHistory()
                } else if item.flags & (lostFlags | FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)) != 0 {
                    history!.lost = true
                } else if item.path != excluding, !item.path.hasPrefix(excluding + "/") {
                    history!.flags[item.path, default: 0] |= item.flags
                }
                continue
            }
            lastID = max(lastID, item.id)
            if item.flags & lostFlags != 0 {
                emit(.gap(from: lastDeliveryAt ?? now, to: now, reason: .watchDropped, detail: ["path": item.path],
                          provenance: "FSEvents reported that it dropped changes under this path (flags \(item.flags)).", clock: clock))
                continue
            }
            if item.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            if item.path == excluding || item.path.hasPrefix(excluding + "/") { continue }
            let thisSecond = Int64(now.timeIntervalSince1970)
            if thisSecond != second {
                flushDropped(now: now)
                (second, inSecond) = (thisSecond, 0)
            }
            inSecond += 1
            guard inSecond <= Self.maxEventsPerSecond else {
                if dropped == 0 { droppedSince = now }
                dropped += 1
                continue
            }
            let (changes, kind) = Self.describe(item.flags)
            var payload = ["changes": changes.joined(separator: ","), "fsevent_id": String(item.id)]
            payload["item"] = kind
            emit(Event(kind: .fileChange, source: "file-watch/FSEvents", subject: Subject(path: item.path), payload: payload,
                       privacyClass: .sensitive, provenance: Self.provenance, clock: clock))
            lastEventAt = now
        }
        lastDeliveryAt = now
    }

    /// One event per changed item, spanning the time the recorder wasn't running.
    private func finishHistory() {
        guard let replayed = history, let emit else { return }
        history = nil
        if replayed.lost {
            emit(.gap(from: replayed.from, to: replayed.to, reason: .watchDropped, detail: ["replayed": "true"],
                      provenance: "FSEvents' history for the time GhostTrace wasn't running is incomplete (it dropped changes, or its ids were reset), so changes then may be missing.",
                      clock: clock))
        }
        let paths = replayed.flags.keys.sorted()
        for path in paths.prefix(Self.maxReplayedPaths) {
            let (changes, kind) = Self.describe(replayed.flags[path]!)
            var payload = ["changes": changes.joined(separator: ","), "replayed": "true"]
            payload["item"] = kind
            emit(Event(kind: .fileChange, source: "file-watch/FSEvents-history", occurredAt: replayed.from, endedAt: replayed.to,
                       subject: Subject(path: path), payload: payload, quality: .inferred, privacyClass: .sensitive,
                       provenance: Self.historyProvenance, clock: clock))
        }
        if paths.count > Self.maxReplayedPaths {
            emit(.gap(from: replayed.from, to: replayed.to, reason: .watchDropped,
                      detail: ["dropped_count": String(paths.count - Self.maxReplayedPaths), "replayed": "true"],
                      provenance: "More than \(Self.maxReplayedPaths) items changed while GhostTrace wasn't running; the rest were not recorded.", clock: clock))
        }
    }

    private func flushDropped(now: Date) {
        guard dropped > 0, let since = droppedSince, let emit else { return }
        emit(.gap(from: since, to: now, reason: .watchDropped, detail: ["dropped_count": String(dropped)],
                  provenance: "More than \(Self.maxEventsPerSecond) file changes a second; the rest were not recorded.", clock: clock))
        (dropped, droppedSince) = (0, nil)
    }

    static let changeNames: [(flag: Int, name: String)] = [
        (kFSEventStreamEventFlagItemCreated, "created"), (kFSEventStreamEventFlagItemRemoved, "removed"),
        (kFSEventStreamEventFlagItemRenamed, "renamed"), (kFSEventStreamEventFlagItemModified, "modified"),
        (kFSEventStreamEventFlagItemInodeMetaMod, "metadata"), (kFSEventStreamEventFlagItemXattrMod, "xattr"),
        (kFSEventStreamEventFlagItemChangeOwner, "owner"), (kFSEventStreamEventFlagItemFinderInfoMod, "finder_info"),
        (kFSEventStreamEventFlagItemCloned, "cloned"), (kFSEventStreamEventFlagRootChanged, "root_changed"),
    ]

    /// The change names in `flags`, and whether the item is a file, folder or symlink.
    static func describe(_ flags: FSEventStreamEventFlags) -> (changes: [String], item: String?) {
        let item: String? = if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 { "file" }
            else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 { "folder" }
            else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsSymlink) != 0 { "symlink" }
            else { nil }
        return (changeNames.filter { flags & FSEventStreamEventFlags($0.flag) != 0 }.map(\.name), item)
    }

    /// Symlinks resolved (FSEvents reports `/private/var/...` for `/var/...`). A missing item resolves through its nearest existing parent.
    public static func canonicalPath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if let resolved = realpath(standardized, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (standardized as NSString).deletingLastPathComponent
        guard parent != standardized, !parent.isEmpty else { return standardized }
        return (canonicalPath(parent) as NSString).appendingPathComponent((standardized as NSString).lastPathComponent)
    }
}
