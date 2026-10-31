import Foundation
import InvestigationKit
import RecorderCore
import XPC

/// Serves the contract on one transport (ADR 0005). On the Unix-domain socket only peers running as the same user are
/// answered (`getpeereid`); the socket's directory is expected to be 0700 and the socket itself is made 0600.
/// Over XPC (`XPCTransport.swift`) only programs signed by the same team are answered, and no socket exists.
public final class RecorderServer: @unchecked Sendable {
    private let path: String
    let handler: @Sendable (Request) async -> Response
    let transport: IPC.Transport
    var listener: XPCListener?
    private let queue = DispatchQueue(label: "ghosttrace.ipc.accept")
    private var source: (any DispatchSourceRead)?

    public init(path: String, transport: IPC.Transport = .socket, handler: @escaping @Sendable (Request) async -> Response) {
        self.path = path
        self.transport = transport
        self.handler = handler
    }

    /// The caller must hold the single-recorder lock, so any existing socket file is stale and is replaced.
    public func start() throws {
        if transport == .xpc { return try startXPC() }
        let fd = try makeSocket()
        do {
            unlink(path)
            try withAddress(path) { address, length in
                guard bind(fd, address, length) == 0 else { throw posixError("bind \(path)") }
            }
            guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else { throw posixError("listen \(path)") }
        } catch {
            close(fd)
            throw error
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            guard let self else { close(client); return }
            serve(client)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        source?.cancel()
        source = nil
        if transport == .socket { unlink(path) }
    }

    /// Reads the request on the accept queue (bounded by the socket timeout), answers from a task.
    private func serve(_ fd: Int32) {
        func finish(_ response: Response) {
            try? writeMessage(fd, response)
            close(fd)
        }
        configure(fd, timeout: 5)
        guard peerIsCurrentUser(fd) else {
            return finish(.failure(.permissionDenied, "Only processes running as the recorder's user may connect."))
        }
        let data: Data
        do {
            data = try readMessage(fd)
        } catch {
            return finish(.failure(.badRequest, "Unreadable request: \(error)"))
        }
        switch decodeRequest(data) {
        case .failure(let error): finish(Response(error: error))
        case .success(let request):
            let handler = handler
            Task { finish(await handler(request)) }
        }
    }
}

/// What every transport checks before the handler runs: size, readable JSON, then the API version.
func decodeRequest(_ data: Data) -> Result<Request, ServiceError> {
    guard data.count <= IPC.maxMessageBytes else { return .failure(ServiceError(.protocolError, "Message exceeds \(IPC.maxMessageBytes) bytes.")) }
    let request: Request
    do {
        request = try GhostTraceJSON.decoder().decode(Request.self, from: data)
    } catch {
        return .failure(ServiceError(.badRequest, "Unreadable request: \(error)"))
    }
    guard request.apiVersion == IPC.apiVersion else {
        return .failure(ServiceError(.unsupportedVersion, "Recorder speaks API version \(IPC.apiVersion), request used \(request.apiVersion)."))
    }
    return .success(request)
}

/// Synchronous client: one connection per request. Every failure surfaces as a `ServiceError`.
public struct RecorderClient: Sendable {
    public var socketPath: String
    public var timeout: Int
    public var transport: IPC.Transport
    /// Stamped on every request.
    public var client: Request.Client?

    /// An explicit `socketPath` always means the socket; otherwise the environment decides (`IPC.Transport.client`).
    public init(socketPath: String? = nil, timeout: Int = 10, client: Request.Client? = nil) {
        self.socketPath = socketPath ?? GhostTracePaths.socket
        self.timeout = timeout
        self.client = client
        transport = socketPath == nil ? .client() : .socket
    }

    public func status() throws -> RecorderStatus { try expect(\.status, from: Request(method: .status)) }
    public func events(_ query: EventQuery) throws -> EventPage { try expect(\.page, from: Request(method: .events, query: query)) }
    public func event(id: UUID) throws -> Event { try expect(\.event, from: Request(method: .event, eventID: id)) }
    public func pause() throws -> RecorderStatus { try expect(\.status, from: Request(method: .pause)) }
    public func resume() throws -> RecorderStatus { try expect(\.status, from: Request(method: .resume)) }
    /// The recorder reads the power log first, which takes about 3 s; use a client timeout well above that.
    public func investigateWake(_ window: DateInterval) throws -> WakeInvestigation {
        try expect(\.investigation, from: Request(method: .investigateWake, window: window))
    }
    public func resources(_ window: DateInterval, top: Int = 10, points: Int = 60) throws -> ResourceSummary {
        try expect(\.resources, from: Request(method: .resources, window: window, top: top, points: points))
    }
    public func live() throws -> SystemReading { try expect(\.live, from: Request(method: .live)) }
    public func investigateMemory(_ window: DateInterval) throws -> MemoryInvestigation {
        try expect(\.memoryInvestigation, from: Request(method: .investigateMemory, window: window))
    }
    public func investigateFileChange(path: String, _ window: DateInterval) throws -> FileChangeInvestigation {
        try expect(\.fileChangeInvestigation, from: Request(method: .investigateFileChange, window: window, path: path))
    }
    /// Battery and network read the power log first (for dark wakes), as `investigateWake` does.
    public func investigateBattery(_ window: DateInterval) throws -> BatteryInvestigation {
        try expect(\.batteryInvestigation, from: Request(method: .investigateBattery, window: window))
    }
    public func investigateNetwork(_ window: DateInterval) throws -> NetworkInvestigation {
        try expect(\.networkInvestigation, from: Request(method: .investigateNetwork, window: window))
    }
    public func investigateDisk(_ window: DateInterval) throws -> DiskInvestigation {
        try expect(\.diskInvestigation, from: Request(method: .investigateDisk, window: window))
    }
    public func watch(add path: String) throws -> RecorderStatus { try expect(\.status, from: Request(method: .watchAdd, path: path)) }
    public func watch(remove path: String) throws -> RecorderStatus { try expect(\.status, from: Request(method: .watchRemove, path: path)) }
    public func configure(sampleInterval: TimeInterval) throws -> RecorderStatus {
        try expect(\.status, from: Request(method: .configure, sampleInterval: sampleInterval))
    }
    public func configure(mcpAccess: Bool) throws -> RecorderStatus { try expect(\.status, from: Request(method: .configure, mcpAccess: mcpAccess)) }
    public func configure(systemMonitor: Bool) throws -> RecorderStatus {
        try expect(\.status, from: Request(method: .configure, systemMonitor: systemMonitor))
    }

    /// Returns the response, or throws its `error`.
    public func send(_ request: Request) throws -> Response {
        var request = request
        if let client { request.client = client }
        let response = try transport == .xpc ? sendOverXPC(request) : sendOverSocket(request)
        if let error = response.error { throw error }
        return response
    }

    private func sendOverSocket(_ request: Request) throws -> Response {
        let fd = try makeSocket()
        defer { close(fd) }
        GhostTraceIPC.configure(fd, timeout: timeout)
        try withAddress(socketPath) { address, length in
            guard connect(fd, address, length) == 0 else {
                let reason = String(cString: strerror(errno))
                if errno == EACCES || errno == EPERM {
                    throw ServiceError(.permissionDenied, "Cannot open \(socketPath): \(reason).")
                }
                throw ServiceError(.recorderNotRunning, "No recorder is listening at \(socketPath) (\(reason)). Start RecorderAgent first.")
            }
        }
        guard peerIsCurrentUser(fd) else {
            throw ServiceError(.permissionDenied, "The process at \(socketPath) runs as a different user; refusing to talk to it.")
        }
        let response: Response
        do {
            try writeMessage(fd, request)
            response = try GhostTraceJSON.decoder().decode(Response.self, from: readMessage(fd))
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError(.protocolError, "Unreadable reply from the recorder: \(error)")
        }
        return response
    }

    private func expect<T>(_ field: KeyPath<Response, T?>, from request: Request) throws -> T {
        guard let value = try send(request)[keyPath: field] else {
            throw ServiceError(.protocolError, "The recorder's reply to '\(request.method.rawValue)' was missing its result.")
        }
        return value
    }
}

// MARK: - Socket plumbing (sys/socket.h, sys/un.h)

func makeSocket() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw posixError("socket") }
    return fd
}

func configure(_ fd: Int32, timeout seconds: Int) {
    var on: Int32 = 1
    // A peer that hangs up must produce EPIPE, not kill the process with SIGPIPE.
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var limit = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
}

func peerIsCurrentUser(_ fd: Int32) -> Bool {
    var uid: uid_t = 0
    var gid: gid_t = 0
    return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
}

func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else {
        throw ServiceError(.badRequest, "Socket path is \(bytes.count) bytes; the limit is \(capacity - 1): \(path). Set a shorter GHOSTTRACE_HOME.")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return try withUnsafePointer(to: &address) {
        try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

func writeMessage(_ fd: Int32, _ value: some Encodable) throws {
    var data = try GhostTraceJSON.encoder().encode(value)
    data.append(0x0A)
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw posixError("write") }
            offset += written
        }
    }
}

/// Reads up to the first newline; fails on timeout, oversize, or a peer that closes without sending a line.
func readMessage(_ fd: Int32) throws -> Data {
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = read(fd, &chunk, chunk.count)
        if count < 0, errno == EINTR { continue }
        if count < 0 { throw posixError(errno == EAGAIN ? "read (timed out)" : "read") }
        guard count > 0 else { throw ServiceError(.protocolError, "Connection closed before a complete message arrived.") }
        if let newline = chunk[..<count].firstIndex(of: 0x0A) {
            data.append(contentsOf: chunk[..<newline])
            return data
        }
        data.append(contentsOf: chunk[..<count])
        guard data.count <= IPC.maxMessageBytes else { throw ServiceError(.protocolError, "Message exceeds \(IPC.maxMessageBytes) bytes.") }
    }
}

func posixError(_ operation: String) -> ServiceError {
    ServiceError(.protocolError, "\(operation): \(String(cString: strerror(errno)))")
}
