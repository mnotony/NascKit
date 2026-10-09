import Foundation
import os

/// Phoenix channel actor wrapping URLSessionWebSocketTask, connecting to nasc's
/// `/client` socket. Manages connection, join, heartbeat, call/cast, and pushes.
/// (Harvested from RelayKit, adapted to nasc.)
public actor PhoenixChannel: ChannelProtocol {
    private var webSocket: URLSessionWebSocketTask?
    private var refCounter: UInt64 = 2 // 1 reserved for join
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var pushContinuation: AsyncStream<InFrame>.Continuation?
    private(set) var joinRef: String = "1"
    private(set) var topic: String = ""
    private var heartbeatTask: Task<Void, Never>?
    private var readerTask: Task<Void, Never>?
    /// Frames received so far: any of them proves the socket is alive.
    private var inbound = 0
    public private(set) var isConnected = false
    private let joinTimeout: Duration
    private let callTimeout: Duration
    private let heartbeatInterval: Duration
    private let heartbeatTimeout: Duration

    public nonisolated let pushes: AsyncStream<InFrame>

    /// One session for every channel (a session per connection was never invalidated). Offline, a
    /// connect fails at once rather than waiting for the network: the live feeds retry on their own.
    private static let session = URLSession(configuration: .default)

    /// A join, a call or a heartbeat that gets no reply within its timeout fails with `timeout`. A
    /// heartbeat unanswered while nothing else arrives also drops the connection: the socket is dead
    /// even if it hasn't said so.
    public init(
        joinTimeout: Duration = .seconds(15),
        callTimeout: Duration = .seconds(30),
        heartbeatInterval: Duration = .seconds(30),
        heartbeatTimeout: Duration = .seconds(10)
    ) {
        self.joinTimeout = joinTimeout
        self.callTimeout = callTimeout
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatTimeout = heartbeatTimeout

        var continuation: AsyncStream<InFrame>.Continuation!
        self.pushes = AsyncStream { continuation = $0 }
        self.pushContinuation = continuation
    }

    /// Connect to nasc's `/client` socket and join `topic` (e.g. `lobby` or
    /// `session:<id>`). `serverURL` is like `ws://127.0.0.1:4100` (no trailing slash).
    public func connect(serverURL: String, credential: String, topic: String) async throws {
        self.topic = topic

        // URLs carry no whitespace — drop any stray trailing text from the input.
        let base = serverURL.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? serverURL
        // Present the device credential only when we have one; an empty value would be rejected,
        // so omit the param entirely and take nasc's open (dual-accept) path during migration.
        var wsURL = "\(base)/client/websocket?vsn=2.0.0"
        if !credential.isEmpty {
            let encoded = credential.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? credential
            wsURL += "&credential=\(encoded)"
        }
        // The error is shown on screen: name the server, never the URL that carries the credential.
        guard let url = URL(string: wsURL) else { throw ChannelError.invalidURL(base) }

        Log.channel.info("Connecting to \(serverURL, privacy: .public)/client/websocket [\(topic, privacy: .public)]")

        let ws = Self.session.webSocketTask(with: url)
        ws.resume()
        self.webSocket = ws

        readerTask = Task { [weak self] in await self?.readerLoop() }

        // Every failure closes the socket: a connect that throws leaves nothing running.
        let joinFrame = OutFrame(joinRef: joinRef, refID: joinRef, topic: topic, event: "phx_join", payload: [:])
        let reply: [String: Any]
        do {
            reply = try await request(joinFrame, timeout: joinTimeout)
        } catch {
            disconnect()
            // nasc refuses a missing or bad credential at the upgrade (403), before any join.
            if let status = (ws.response as? HTTPURLResponse)?.statusCode, status == 401 || status == 403 {
                throw ChannelError.joinFailed("credential \(credential.isEmpty ? "required" : "refused") (HTTP \(status))")
            }
            throw error
        }

        guard (reply["status"] as? String) == "ok" else {
            disconnect()
            let reason = (reply["response"] as? [String: Any])?["reason"] as? String ?? "join failed"
            throw ChannelError.joinFailed(reason)
        }

        Log.channel.info("Joined \(topic, privacy: .public)")
        isConnected = true

        heartbeatTask = Task { [weak self] in await self?.heartbeatLoop() }
    }

    /// Send an event and wait for the reply (`callTimeout`). Returns the `response`.
    public func call(event: String, payload: [String: Any] = [:]) async throws -> [String: Any] {
        let frame = OutFrame(joinRef: joinRef, refID: nextRef(), topic: topic, event: event, payload: payload)
        let result = try await request(frame, timeout: callTimeout)

        switch result["status"] as? String ?? "" {
        case "ok":
            return result["response"] as? [String: Any] ?? [:]
        case "error":
            let reason = (result["response"] as? [String: Any])?["reason"] as? String ?? "unknown error"
            throw ChannelError.callFailed(reason)
        default:
            return result
        }
    }

    /// Send an event without waiting for a reply.
    public func cast(event: String, payload: [String: Any] = [:]) async throws {
        let frame = OutFrame(joinRef: joinRef, refID: nextRef(), topic: topic, event: event, payload: payload)
        try await send(frame)
    }

    public func disconnect() {
        heartbeatTask?.cancel()
        readerTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        pushContinuation?.finish()
        for (_, cont) in pending { cont.resume(throwing: ChannelError.disconnected) }
        pending.removeAll()
    }

    // MARK: - Private

    /// Send `frame` and wait for its reply payload. The deadline runs from the start, not from when
    /// the send completes, so a send that can't go out times out too; cancelling the caller fails it
    /// at once.
    private func request(_ frame: OutFrame, timeout: Duration) async throws -> [String: Any] {
        let refID = frame.refID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
                pending[refID] = cont
                Task {
                    do { try await self.send(frame) } catch { self.fail(refID, with: error) }
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    self.fail(refID, with: ChannelError.timeout)
                }
            }
        } onCancel: {
            Task { await self.fail(refID, with: CancellationError()) }
        }
    }

    /// Fail a pending reply, if it is still waiting.
    private func fail(_ refID: String, with error: Error) {
        pending.removeValue(forKey: refID)?.resume(throwing: error)
    }

    private func nextRef() -> String {
        refCounter += 1
        return String(refCounter)
    }

    private func send(_ frame: OutFrame) async throws {
        guard let ws = webSocket else { throw ChannelError.disconnected }
        try await ws.send(.string(frame.serialize()))
    }

    private func readerLoop() async {
        guard let ws = webSocket else { return }
        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                inbound += 1
                if case .string(let text) = message, let frame = try? InFrame.parse(text) {
                    await handleFrame(frame)
                }
            } catch {
                disconnect()
                break
            }
        }
    }

    private func handleFrame(_ frame: InFrame) async {
        if frame.event == "phx_reply" {
            if let refID = frame.refID, let cont = pending.removeValue(forKey: refID) {
                cont.resume(returning: frame.payload)
            }
        } else {
            pushContinuation?.yield(frame)
        }
    }

    private func heartbeatLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: heartbeatInterval)
            guard !Task.isCancelled else { break }
            let frame = OutFrame(joinRef: nil, refID: nextRef(), topic: "phoenix", event: "heartbeat", payload: [:])
            let before = inbound
            do {
                _ = try await request(frame, timeout: heartbeatTimeout)
            } catch {
                guard !Task.isCancelled else { break }  // a deliberate disconnect, not a drop
                // Anything received meanwhile proves the socket alive: the reply is just queued behind
                // it (a session replay). Only silence is a dead socket.
                if inbound > before { continue }
                disconnect()
                break
            }
        }
    }
}

public enum ChannelError: Error, LocalizedError {
    case invalidURL(String)
    case joinFailed(String)
    case callFailed(String)
    case timeout
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .joinFailed(let reason): return "Join failed: \(reason)"
        case .callFailed(let reason): return "Call failed: \(reason)"
        case .timeout: return "Request timed out"
        case .disconnected: return "Disconnected"
        }
    }
}
