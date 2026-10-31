// The only writer of the event database. Runs until SIGINT/SIGTERM, under launchd (the app's LaunchAgent) or from a terminal.
import Collectors
import EventStore
import Foundation
import GhostTraceIPC
import RecorderCore

func fail(_ message: String) -> Never {
    log(message)
    exit(EXIT_FAILURE)
}

// Everything the recorder creates (database, WAL, socket, lock) is owner-only.
umask(0o077)
let home = GhostTracePaths.home
do {
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
} catch {
    fail("cannot create \(home.path): \(error)")
}
// The socket's access model relies on this directory being private to the user.
guard chmod(home.path, 0o700) == 0 else { fail("cannot make \(home.path) private: \(String(cString: strerror(errno)))") }

// One recorder per home: hold an exclusive lock for the life of the process.
let lockFD = open(GhostTracePaths.lock, O_CREAT | O_RDWR, 0o600)
guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { fail("another RecorderAgent is already running for \(home.path).") }

let store: EventStore
do {
    store = try EventStore(path: GhostTracePaths.database)
} catch {
    fail("cannot open \(GhostTracePaths.database): \(error)")
}

let recorder = Recorder(store: store, clock: .live, collectors: [WorkspaceCollector.appLifecycle(), WorkspaceCollector.sleepWake()],
                        sampler: ResourceSampler(), watcher: FileWatcher(excluding: home.path))
// Under launchd the recorder answers XPC only (no socket); from a terminal it keeps the socket (ADR 0005).
let transport = IPC.Transport.recorder()
let server = RecorderServer(path: GhostTracePaths.socket, transport: transport) { request in
    let response = await recorder.handle(request)
    // After the reply has been sent; decoding a big query is the recorder's largest allocation.
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { releaseFreeMemory() }
    return response
}

func shutdown(exitCode: Int32) async -> Never {
    server.stop()
    await recorder.shutdown()
    exit(exitCode)
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signalSources = [SIGINT, SIGTERM].map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { Task { await shutdown(exitCode: EXIT_SUCCESS) } }
    source.resume()
    return source
}

Task {
    do {
        try await recorder.start()
        try server.start()
        log("recording to \(store.path); listening on \(transport == .xpc ? "Mach service \(IPC.machServiceName)" : GhostTracePaths.socket)", level: .default)
    } catch {
        log("startup failed: \(error)")
        await shutdown(exitCode: EXIT_FAILURE)
    }
}

// NSWorkspace delivers its notifications through the main run loop.
RunLoop.main.run()
