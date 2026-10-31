import Foundation
import RecorderCore
import XPC

extension IPC {
    /// The recorder's Mach service, advertised by the LaunchAgent plist (`MachServices`).
    public static let machServiceName = "com.amoghkhairate.GhostTrace.recorder"

    /// How a program reaches the recorder (docs/adr/0005-reliable-background-operation.md). The launchd recorder answers
    /// XPC only, so a socket can't undo the peer requirement; terminal and test recorders answer on the socket only.
    public enum Transport: Sendable, Equatable {
        case socket, xpc

        /// Clients: a custom home means a terminal recorder, which has no Mach service.
        public static func client(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Transport {
            environment["GHOSTTRACE_HOME"]?.isEmpty == false ? .socket : .xpc
        }

        /// The recorder: launchd sets XPC_SERVICE_NAME to the job's label. A shell, a test or another job never sets this one.
        public static func recorder(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Transport {
            environment["XPC_SERVICE_NAME"] == IPC.machServiceName ? .xpc : .socket
        }
    }
}

/// A request or reply over XPC: the JSON the socket carries, so dates, `apiVersion` and validation behave identically.
struct Envelope: Codable {
    var json: Data

    init(_ response: Response) { json = (try? GhostTraceJSON.encoder().encode(response)) ?? Data() }
    init(json: Data) { self.json = json }
}

extension RecorderServer {
    /// Registers the Mach service (the plist's `MachServices` entry makes launchd hand it over) and refuses any
    /// program not signed by this build's team before a message is read. Replies arrive from a task, after the handler.
    func startXPC() throws {
        let handler = handler
        listener = try XPCListener(service: IPC.machServiceName, requirement: .isFromSameTeam()) { incoming in
            incoming.accept { (message: XPCReceivedMessage) -> (any Encodable)? in
                let json: Data
                do {
                    json = try message.decode(as: Envelope.self).json
                } catch {
                    return Envelope(.failure(.badRequest, "Unreadable request: \(error)"))
                }
                switch decodeRequest(json) {
                case .failure(let error): return Envelope(Response(error: error))
                case .success(let request):
                    let pending = PendingReply(message: message)
                    Task { pending.message.reply(Envelope(await handler(request))) }
                    return nil
                }
            }
        }
    }
}

/// `XPCReceivedMessage` isn't `Sendable`, but replying later from another thread is what its `reply` is for.
private struct PendingReply: @unchecked Sendable {
    let message: XPCReceivedMessage
}

extension RecorderClient {
    /// One session per request, like the socket's one connection. The reply arrives on an XPC queue; this waits `timeout` s.
    /// The session demands the recorder be signed by the same team, so a fake recorder can't answer.
    func sendOverXPC(_ request: Request) throws -> Response {
        let reply = Reply()
        do {
            let session = try XPCSession(machService: IPC.machServiceName, requirement: .isFromSameTeam())
            defer { session.cancel(reason: "request finished") }
            try session.send(Envelope(json: GhostTraceJSON.encoder().encode(request))) { (result: Result<Envelope, any Error>) in
                reply.finish(result)
            }
            guard reply.wait(seconds: timeout), let result = reply.result else {
                throw ServiceError(.protocolError, "The recorder did not answer within \(timeout) s.")
            }
            return try GhostTraceJSON.decoder().decode(Response.self, from: result.get().json)
        } catch let error as ServiceError {
            throw error
        } catch let error as XPCRichError {
            throw Self.failure(error)
        } catch {
            throw ServiceError(.protocolError, "Unreadable reply from the recorder: \(error)")
        }
    }

    /// shortcut: XPCRichError exposes only its text, so "interrupted" is matched by substring; revisit if macOS rewords it.
    /// "Interrupted" is what both sides see when a peer requirement fails (checked with a team-signed and an ad-hoc probe,
    /// in both directions); anything else is a failed lookup, meaning no recorder holds the Mach service.
    private static func failure(_ error: XPCRichError) -> ServiceError {
        if "\(error)".contains("interrupted") {
            return ServiceError(.permissionDenied, "The recorder closed the connection. It only answers GhostTrace programs signed by the same team, "
                + "so sign this build with scripts/sign-cli.sh; if this build is signed, the recorder stopped while answering.")
        }
        return ServiceError(.recorderNotRunning, "No recorder is listening on \(IPC.machServiceName) (\(error)). Turn on Record in Background in the menu bar app; "
            + "for a terminal recorder, set the same GHOSTTRACE_HOME for RecorderAgent and ghosttrace.")
    }
}

/// Carries the asynchronous reply back to the waiting caller.
private final class Reply: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private(set) var result: Result<Envelope, any Error>?

    func finish(_ result: Result<Envelope, any Error>) {
        self.result = result
        done.signal()
    }

    func wait(seconds: Int) -> Bool { done.wait(timeout: .now() + .seconds(seconds)) == .success }
}
