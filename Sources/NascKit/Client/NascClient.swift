import Foundation

/// High-level nasc client: create a session, attach to its live event stream, and
/// drive it (prompt / approve / interrupt). Mirrors the nasc-cli flow.
public actor NascClient {
    private let endpoint: NascEndpoint
    private var session: PhoenixChannel?
    public private(set) var sessionID: String?

    public init(endpoint: NascEndpoint = NascEndpoint()) {
        self.endpoint = endpoint
    }

    /// Create a new session via the lobby. Returns `(id, slug)`.
    public func createSession(persona: String? = nil) async throws -> (id: String, slug: String) {
        let lobby = PhoenixChannel()
        try await lobby.connect(serverURL: endpoint.serverURL, token: endpoint.token, topic: NascEndpoint.lobbyTopic)
        let payload: [String: Any] = persona.map { ["persona_slug": $0] } ?? [:]
        let resp = try await lobby.call(event: "create_session", payload: payload)
        await lobby.disconnect()

        guard let id = resp["id"] as? String else {
            throw ChannelError.callFailed("no session id in reply")
        }
        return (id, resp["slug"] as? String ?? id)
    }

    /// Attach to a session: join `session:<id>` and return a live event stream
    /// (the log is replayed on join, then live events follow).
    public func attach(sessionID: String) async throws -> AsyncStream<NascEvent> {
        let ch = PhoenixChannel()
        try await ch.connect(serverURL: endpoint.serverURL, token: endpoint.token, topic: "session:\(sessionID)")
        self.session = ch
        self.sessionID = sessionID

        let pushes = ch.pushes
        return AsyncStream { continuation in
            let task = Task {
                for await frame in pushes {
                    if let event = NascEvent.from(frame: frame) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func prompt(_ content: String) async throws {
        _ = try await requireSession().call(event: "prompt", payload: ["content": content])
    }

    public func decide(requestID: String, approve: Bool) async throws {
        _ = try await requireSession().call(event: "decision", payload: ["request_id": requestID, "approve": approve])
    }

    public func interrupt(_ content: String) async throws {
        _ = try await requireSession().call(event: "interrupt", payload: ["content": content])
    }

    public func disconnect() async {
        await session?.disconnect()
        session = nil
        sessionID = nil
    }

    private func requireSession() throws -> PhoenixChannel {
        guard let session else { throw ChannelError.disconnected }
        return session
    }
}
