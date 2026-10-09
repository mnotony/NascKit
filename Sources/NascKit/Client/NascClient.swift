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

    /// Create a new session via the lobby. Returns `(id, slug)`. A `project` name lets nasc route
    /// the session to an agent that can reach it (e.g. the one holding that project's client VPN).
    public func createSession(persona: String? = nil, project: String? = nil, autonomy: Bool = false) async throws -> (id: String, slug: String) {
        var payload: [String: Any] = [:]
        if let persona { payload["persona_slug"] = persona }
        if let project { payload["project"] = project }
        // "turn this task loose": the run auto-approves safe tool calls; consequential ones still pause.
        if autonomy { payload["autonomy"] = true }
        let resp = try await withLobby { try await $0.call(event: "create_session", payload: payload) }

        guard let id = resp["id"] as? String else {
            throw ChannelError.callFailed("no session id in reply")
        }
        return (id, resp["slug"] as? String ?? id)
    }

    /// The projects the user can start a session on — the picker source.
    public func listProjects() async throws -> [Project] {
        let resp = try await withLobby { try await $0.call(event: "list_projects", payload: [:]) }

        let arr = resp["projects"] as? [[String: Any]] ?? []
        return arr.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            return Project(name: name, capability: dict["capability"] as? String, title: dict["title"] as? String)
        }
    }

    /// List recent sessions (newest first) via the lobby.
    public func listSessions() async throws -> [SessionSummary] {
        try await withLobby { try await Self.fetchSessions($0) }
    }

    /// Rename a session (sets its title).
    public func renameSession(id: String, title: String) async throws {
        try await lobbyMutate("rename_session", ["id": id, "title": title])
    }

    /// Delete a session (cascades its events).
    public func deleteSession(id: String) async throws {
        try await lobbyMutate("delete_session", ["id": id])
    }

    /// Delete several sessions over one lobby connection. Returns the ids that were not deleted;
    /// throws only if the lobby can't be joined (nothing was attempted).
    public func deleteSessions(ids: [String]) async throws -> [String] {
        try await withLobby { lobby in
            await Self.deleteEach(ids, listed: { Set(try await Self.fetchSessions(lobby).map(\.id)) }) { id in
                _ = try await lobby.call(event: "delete_session", payload: ["id": id])
            }
        }
    }

    /// Delete `ids` in order and return the ones that failed. A server refusal fails just that id;
    /// any other error means the socket is gone, so that id and every remaining one fail untried —
    /// rather than each waiting out the 30s call timeout. A failed id that is no longer `listed` was
    /// deleted after all: nasc refuses an already-archived session exactly as it does a real
    /// failure, and a timed-out delete may have landed. If the listing fails, every failure stands.
    static func deleteEach(
        _ ids: [String],
        listed: () async throws -> Set<String>,
        using delete: (String) async throws -> Void
    ) async -> [String] {
        var failed: [String] = []
        for (i, id) in ids.enumerated() {
            do {
                try await delete(id)
            } catch ChannelError.callFailed {
                failed.append(id)
            } catch {
                failed += ids[i...]
                break
            }
        }
        guard !failed.isEmpty, let still = try? await listed() else { return failed }
        return failed.filter(still.contains)
    }

    /// Live session list: the current list, then again whenever any device creates/renames/deletes
    /// a session (`sessions_changed`). Reconnects on its own after a drop (`.lost` until it's back).
    public nonisolated func lobbyUpdates() -> AsyncStream<LiveUpdate<[SessionSummary]>> {
        let endpoint = endpoint
        return Self.resilient { try await Self.lobbyFeed(endpoint, refreshOn: ["sessions_changed"], fetch: { try await Self.fetchSessions($0) }) }
    }

    private func lobbyMutate(_ event: String, _ payload: [String: Any]) async throws {
        _ = try await withLobby { try await $0.call(event: event, payload: payload) }
    }

    /// Join the lobby, run `body`, and close the connection — whether `body` succeeds or throws.
    private func withLobby<T>(_ body: (PhoenixChannel) async throws -> T) async throws -> T {
        let lobby = PhoenixChannel()
        try await lobby.connect(serverURL: endpoint.serverURL, credential: endpoint.credential, topic: NascEndpoint.lobbyTopic)
        do {
            let result = try await body(lobby)
            await lobby.disconnect()
            return result
        } catch {
            await lobby.disconnect()
            throw error
        }
    }

    private static func fetchSessions(_ lobby: PhoenixChannel) async throws -> [SessionSummary] {
        let resp = try await lobby.call(event: "list_sessions", payload: [:])
        let arr = resp["sessions"] as? [[String: Any]] ?? []
        return arr.compactMap { dict in
            guard let id = dict["id"] as? String else { return nil }
            return SessionSummary(
                id: id,
                slug: dict["slug"] as? String ?? id,
                status: dict["status"] as? String,
                title: dict["title"] as? String,
                runState: dict["run_state"] as? String
            )
        }
    }

    /// Live fleet status: the current snapshot, then again whenever agents connect/disconnect or
    /// sessions change. Reconnects on its own after a drop.
    public nonisolated func fleetUpdates() -> AsyncStream<LiveUpdate<FleetStatus>> {
        let endpoint = endpoint
        return Self.resilient {
            try await Self.lobbyFeed(endpoint, refreshOn: ["fleet_changed", "sessions_changed"], fetch: { try await Self.fetchFleet($0) })
        }
    }

    private static func fetchFleet(_ lobby: PhoenixChannel) async throws -> FleetStatus {
        let resp = try await lobby.call(event: "fleet_status", payload: [:])
        return FleetStatus.from(resp)
    }

    // --- agents: roots + autonomy, managed from the phone ---

    /// The fleet's agents with their project roots + autonomy — the Agents screen source.
    public func listAgents() async throws -> [Agent] {
        try await withLobby { try await Self.fetchAgents($0) }
    }

    /// Turn an agent loose (or rein it in): its runs auto-approve safe tool calls.
    public func setAgentAutonomy(agentID: String, on: Bool) async throws {
        try await lobbyMutate("set_agent_autonomy", ["agent_id": agentID, "autonomous": on])
    }

    /// Add a project root to an agent (nasc pushes it to the agent live).
    public func addAgentRoot(agentID: String, path: String) async throws {
        try await lobbyMutate("add_agent_root", ["agent_id": agentID, "path": path])
    }

    /// Remove a project root from an agent.
    public func removeAgentRoot(agentID: String, path: String) async throws {
        try await lobbyMutate("remove_agent_root", ["agent_id": agentID, "path": path])
    }

    /// Live agent list: the current agents, then again on `agents_changed` (roots/autonomy edits)
    /// and `fleet_changed` (connect/disconnect). Reconnects on its own after a drop.
    public nonisolated func agentUpdates() -> AsyncStream<LiveUpdate<[Agent]>> {
        let endpoint = endpoint
        return Self.resilient {
            try await Self.lobbyFeed(endpoint, refreshOn: ["agents_changed", "fleet_changed"], fetch: { try await Self.fetchAgents($0) })
        }
    }

    private static func fetchAgents(_ lobby: PhoenixChannel) async throws -> [Agent] {
        let resp = try await lobby.call(event: "list_agents", payload: [:])
        let arr = resp["agents"] as? [[String: Any]] ?? []
        return arr.compactMap(Agent.from)
    }

    /// Register this device's APNs token so nasc can push it (e.g. on approval needed).
    public func registerDevice(apnsToken: String, env: String = "sandbox", label: String? = nil) async throws {
        var payload: [String: Any] = ["apns_token": apnsToken, "platform": "ios", "apns_env": env]
        if let label { payload["label"] = label }
        _ = try await withLobby { try await $0.call(event: "register_device", payload: payload) }
    }

    /// Attach to a session: join `session:<id>` and return a live event stream
    /// (the log is replayed on join, then live events follow).
    public func attach(sessionID: String) async throws -> AsyncStream<NascEvent> {
        let ch = PhoenixChannel()
        try await ch.connect(serverURL: endpoint.serverURL, credential: endpoint.credential, topic: "session:\(sessionID)")
        self.session = ch
        self.sessionID = sessionID

        let pushes = ch.pushes
        return AsyncStream { continuation in
            let task = Task {
                for await frame in pushes {
                    if frame.endsChannel { break }
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

    /// Neural TTS via nasc's `/tts` proxy (croí). Returns WAV audio bytes.
    public func synthesize(_ text: String, voiceID: String = "bf_emma") async throws -> Data {
        let base = endpoint.httpBase.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
            ?? endpoint.httpBase
        guard let url = URL(string: base + "/tts") else { throw ChannelError.invalidURL(base + "/tts") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Present the device credential when we have one; nasc requires it on `/tts` once the
        // credentials-only flip is on, and ignores it while still dual-accepting.
        if !endpoint.credential.isEmpty {
            request.setValue("Bearer \(endpoint.credential)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "voice_id": voiceID])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
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
