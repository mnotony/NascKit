import Foundation
import os

/// Phoenix channel actor wrapping URLSessionWebSocketTask, connecting to nasc's
/// `/client` socket. Manages connection, join, heartbeat, call/cast, and pushes.
/// (Harvested from RelayKit, adapted to nasc.)
public actor PhoenixChannel: ChannelProtocol {
    private var webSocket: URLSessionWebSocketTask?
    private let session: URLSession
    private var refCounter: UInt64 = 2 // 1 reserved for join
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var pushContinuation: AsyncStream<InFrame>.Continuation?
    private(set) var joinRef: String = "1"
    private(set) var topic: String = ""
    private var heartbeatTask: Task<Void, Never>?
    private var readerTask: Task<Void, Never>?
    public private(set) var isConnected = false

    public nonisolated let pushes: AsyncStream<InFrame>

    public init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)

        var continuation: AsyncStream<InFrame>.Continuation!
        self.pushes = AsyncStream { continuation = $0 }
        self.pushContinuation = continuation
    }

    /// Connect to nasc's `/client` socket and join `topic` (e.g. `lobby` or
    /// `session:<id>`). `serverURL` is like `ws://127.0.0.1:4100` (no trailing slash).
    public func connect(serverURL: String, token: String, topic: String) async throws {
        self.topic = topic

        // URLs carry no whitespace — drop any stray trailing text from the input.
        let base = serverURL.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? serverURL
        let wsURL = "\(base)/client/websocket?vsn=2.0.0&token=\(token)"
        guard let url = URL(string: wsURL) else { throw ChannelError.invalidURL(wsURL) }

        Log.channel.info("Connecting to \(serverURL, privacy: .public)/client/websocket [\(topic, privacy: .public)]")

        let ws = session.webSocketTask(with: url)
        ws.resume()
        self.webSocket = ws

        readerTask = Task { [weak self] in await self?.readerLoop() }

        let joinFrame = OutFrame(joinRef: joinRef, refID: joinRef, topic: topic, event: "phx_join", payload: [:])
        try await send(joinFrame)

        let reply = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            pending[joinRef] = cont
        }

        guard (reply["status"] as? String) == "ok" else {
            let reason = (reply["response"] as? [String: Any])?["reason"] as? String ?? "join failed"
            throw ChannelError.joinFailed(reason)
        }

        Log.channel.info("Joined \(topic, privacy: .public)")
        isConnected = true

        heartbeatTask = Task { [weak self] in await self?.heartbeatLoop() }
    }

    /// Send an event and wait for the reply (30s timeout). Returns the `response`.
    public func call(event: String, payload: [String: Any] = [:]) async throws -> [String: Any] {
        let refID = nextRef()

        let frame = OutFrame(joinRef: joinRef, refID: refID, topic: topic, event: event, payload: payload)

        let result: [String: Any] = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            pending[refID] = cont

            Task { [weak self] in
                guard let self else { cont.resume(throwing: ChannelError.disconnected); return }
                do {
                    try await self.send(frame)
                } catch {
                    if let cont = await self.removePending(refID: refID) { cont.resume(throwing: error) }
                    return
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if let cont = await self.removePending(refID: refID) { cont.resume(throwing: ChannelError.timeout) }
            }
        }

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

    private func removePending(refID: String) -> CheckedContinuation<[String: Any], Error>? {
        pending.removeValue(forKey: refID)
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
                if case .string(let text) = message, let frame = try? InFrame.parse(text) {
                    await handleFrame(frame)
                }
            } catch {
                handleDisconnect()
                break
            }
        }
    }

    private func handleFrame(_ frame: InFrame) async {
        if frame.event == "phx_reply" {
            if let refID = frame.refID, let cont = pending.removeValue(forKey: refID) {
                cont.resume(returning: frame.payload)
            }
        } else if frame.event != "phx_close" {
            pushContinuation?.yield(frame)
        }
    }

    private func handleDisconnect() {
        heartbeatTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        pushContinuation?.finish()
        for (_, cont) in pending { cont.resume(throwing: ChannelError.disconnected) }
        pending.removeAll()
    }

    private func heartbeatLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { break }
            let frame = OutFrame(joinRef: nil, refID: nextRef(), topic: "phoenix", event: "heartbeat", payload: [:])
            if (try? await send(frame)) == nil { break }
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
