import Foundation
import Network

/// Start `listener` and wait until it is accepting connections.
func listen(_ listener: NWListener, on queue: DispatchQueue) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        let resumed = Box(false)
        listener.stateUpdateHandler = { state in
            var first = false
            switch state {
            case .ready, .failed: resumed.update { if !$0 { $0 = true; first = true } }
            default: break
            }
            guard first else { return }
            if case .failed(let error) = state { cont.resume(throwing: error) } else { cont.resume() }
        }
        listener.start(queue: queue)
    }
}

/// An in-process Phoenix v2 socket on loopback, for transport tests. It speaks just enough of the
/// protocol: every frame is `[join_ref, ref, topic, event, payload]`, and a reply is
/// `[join_ref, ref, topic, "phx_reply", {"status": "ok" | "error", "response": {...}}]` — the join
/// on the channel's topic, heartbeats on `phoenix`.
final class PhoenixStub: @unchecked Sendable {
    enum Join { case ok, refuse, ignore }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "phoenix-stub")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var _join: Join = .ok
    private var _answerHeartbeats = true
    private var _replies: [String: [String: Any]] = [:]
    private var _refuse: Set<String> = []
    private var _heartbeats = 0
    private var _joins = 0
    private var _closed = 0
    private var pushing: Task<Void, Never>?

    /// How the stub answers `phx_join`.
    var join: Join {
        get { locked { _join } }
        set { locked { _join = newValue } }
    }
    var answerHeartbeats: Bool {
        get { locked { _answerHeartbeats } }
        set { locked { _answerHeartbeats = newValue } }
    }
    /// The `response` for a call, by event; an event not listed is never answered.
    var replies: [String: [String: Any]] {
        get { locked { _replies } }
        set { locked { _replies = newValue } }
    }
    /// Calls answered with `{"status": "error"}`.
    var refuse: Set<String> {
        get { locked { _refuse } }
        set { locked { _refuse = newValue } }
    }
    var heartbeatsSeen: Int { locked { _heartbeats } }
    var joinsSeen: Int { locked { _joins } }
    /// Connections the client has closed (or that dropped).
    var closedCount: Int { locked { _closed } }

    private(set) var url = ""

    init() throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        try await listen(listener, on: queue)
        url = "ws://127.0.0.1:\(listener.port!.rawValue)"
    }

    func stop() {
        stopPushing()
        dropAll()
        listener.cancel()
    }

    /// Push a frame on every connection every `interval` (inbound traffic that isn't a heartbeat
    /// reply), until `stopPushing()`.
    func startPushing(every interval: Duration) {
        pushing = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let open = self.locked { self.connections }
                for conn in open { self.send(conn, [NSNull(), NSNull(), "lobby", "noise", [String: Any]()]) }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopPushing() {
        pushing?.cancel()
        pushing = nil
    }

    /// Kill every open connection, as a server restart or a dead network would.
    func dropAll() {
        let open = locked { () -> [NWConnection] in
            defer { connections.removeAll() }
            return connections
        }
        open.forEach { $0.cancel() }
    }

    /// Wait (up to `timeout`) until `condition` holds.
    func eventually(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: - Private

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func accept(_ conn: NWConnection) {
        locked { connections.append(conn) }
        conn.start(queue: queue)
        receive(conn)
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || meta?.opcode == .close {
                self.locked { self._closed += 1 }
                return
            }
            if let data, let text = String(data: data, encoding: .utf8) { self.handle(text, on: conn) }
            self.receive(conn)
        }
    }

    private func handle(_ text: String, on conn: NWConnection) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [Any], frame.count == 5,
              let topic = frame[2] as? String, let event = frame[3] as? String else { return }
        let joinRef = frame[0] as? String
        let ref = frame[1] as? String

        switch (topic, event) {
        case ("phoenix", "heartbeat"):
            locked { _heartbeats += 1 }
            if answerHeartbeats { reply(conn, joinRef, ref, topic, "ok", [:]) }
        case (_, "phx_join"):
            locked { _joins += 1 }
            switch join {
            case .ok: reply(conn, joinRef, ref, topic, "ok", [:])
            case .refuse: reply(conn, joinRef, ref, topic, "error", ["reason": "unauthorized"])
            case .ignore: break
            }
        default:
            if refuse.contains(event) {
                reply(conn, joinRef, ref, topic, "error", ["reason": "refused"])
            } else if let response = replies[event] {
                reply(conn, joinRef, ref, topic, "ok", response)
            }
        }
    }

    private func reply(_ conn: NWConnection, _ joinRef: String?, _ ref: String?, _ topic: String, _ status: String, _ response: [String: Any]) {
        send(conn, [joinRef ?? NSNull(), ref ?? NSNull(), topic, "phx_reply", ["status": status, "response": response]])
    }

    private func send(_ conn: NWConnection, _ frame: [Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "reply", metadata: [meta])
        conn.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}

/// A loopback server that accepts TCP connections and never answers the WebSocket upgrade, so the
/// client's first frame can't even be sent — the shape of a socket waiting for connectivity. With
/// `refuseWith`, it answers the upgrade with that HTTP status instead, as nasc does (403) for a
/// credential it won't accept.
final class SilentServer: @unchecked Sendable {
    private let refuseWith: Int?
    private let listener: NWListener
    private let queue = DispatchQueue(label: "silent-server")
    private var connections: [NWConnection] = []
    private(set) var url = ""

    init(refuseWith status: Int? = nil) throws {
        refuseWith = status
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.queue.async { self.connections.append(conn) }
            conn.start(queue: self.queue)
            if let status = self.refuseWith {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                    let response = "HTTP/1.1 \(status) Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                }
            }
        }
        try await listen(listener, on: queue)
        url = "ws://127.0.0.1:\(listener.port!.rawValue)"
    }

    func stop() {
        queue.sync { connections.forEach { $0.cancel() } }
        listener.cancel()
    }
}
