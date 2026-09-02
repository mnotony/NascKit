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
        let lobby = PhoenixChannel()
        try await lobby.connect(serverURL: endpoint.serverURL, token: endpoint.token, topic: NascEndpoint.lobbyTopic)
        var payload: [String: Any] = [:]
        if let persona { payload["persona_slug"] = persona }
        if let project { payload["project"] = project }
        // "turn this task loose": the run auto-approves safe tool calls; consequential ones still pause.
        if autonomy { payload["autonomy"] = true }
        let resp = try await lobby.call(event: "create_session", payload: payload)
        await lobby.disconnect()

        guard let id = resp["id"] as? String else {
            throw ChannelError.callFailed("no session id in reply")
        }
        return (id, resp["slug"] as? String ?? id)
    }

    /// The projects the user can start a session on — the picker source.
    public func listProjects() async throws -> [Project] {
        let lobby = PhoenixChannel()
        try await lobby.connect(serverURL: endpoint.serverURL, token: endpoint.token, topic: NascEndpoint.lobbyTopic)
        let resp = try await lobby.call(event: "list_projects", payload: [:])
        await lobby.disconnect()

        let arr = resp["projects"] as? [[String: Any]] ?? []
        return arr.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            return Project(name: name, capability: dict["capability"] as? String, title: dict["title"] as? String)
        }
    }

    /// List recent sessions (newest first) via the lobby.
    public func listSessions() async throws -> [SessionSummary] {
        let lobby = PhoenixChannel()
        try await lobby.connect(serverURL: endpoint.serverURL, token: endpoint.token, topic: NascEndpoint.lobbyTopic)
        let resp = try await lobby.call(event: "list_sessions", payload: [:])
        await lobby.disconnect()

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

    /// Rename a session (sets its title).
    public func renameSession(id: String, title: String) async throws {
        try await lobbyMutate("rename_session", ["id": id, "title": title])
    }

    /// Delete a session (cascades its events).
    public func deleteSession(id: String) async throws {
        try await lobbyMutate("delete_session", ["id": id])
    }

    /// Live session list: yields the current list, then re-yields whenever any device
    /// creates/renames/deletes a session (server broadcasts `sessions_changed`).
    public func lobbyUpdates() async throws -> AsyncStream<[SessionSummary]> {
        let lobby = PhoenixChannel()
        try await lobby.connect(serverURL: endpoint.serverURL, token: endpoint.token, topic: NascEndpoint.lobbyTopic)
        let pushes = lobby.pushes

        return AsyncStream { continuation in
            let task = Task {
                if let list = try? await Self.fetchSessions(lobby) { continuation.yield(list) }
                for await frame in pushes where frame.event == "sessions_changed" {
                    if let list = try? await Self.fetchSessions(lobby) { continuation.yield(list) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await lobby.disconnect() }
            }
        }
    }

    private func lobbyMutate(_ event: String, _ payload: [String: Any]) async throws {
        let lobby = PhoenixChannel()
        try await lobby.connect(serverURL: endpoint.serverURL, token: endpoint.token, topic: NascEndpoint.lobbyTopic)
        _ = try await lobby.call(event: event, payload: payload)
        await lobby.disconnect()
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

    /// Live fleet status: yields the current snapshot, then re-yields whenever agents
    /// connect/disconnect or sessions change.
    public func fleetUpdates() async throws -> AsyncStream<FleetStatus> {
        let lobby = PhoenixChannel()
        try await lobby.connect(serverURL: endpoint.serverURL, token: endpoint.token, topic: NascEndpoint.lobbyTopic)
        let pushes = lobby.pushes

        return AsyncStream { continuation in
            let task = Task {
                if let status = try? await Self.fetchFleet(lobby) { continuation.yield(status) }
                for await frame in pushes where frame.event == "fleet_changed" || frame.event == "sessions_changed" {
                    if let status = try? await Self.fetchFleet(lobby) { continuation.yield(status) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await lobby.disconnect() }
            }
        }
    }

    private static func fetchFleet(_ lobby: PhoenixChannel) async throws -> FleetStatus {
        let resp = try await lobby.call(event: "fleet_status", payload: [:])
        return FleetStatus.from(resp)
    }

    // --- agents: roots + autonomy, managed from the phone ---

    /// The fleet's agents with their project roots + autonomy — the Agents screen source.
    public func listAgents() async throws -> [Agent] {
        let lobby = PhoenixChannel()
        try await lobby.connect(serverURL: endpoint.serverURL, token: endpoint.token, topic: NascEndpoint.lobbyTopic)
        let agents = try await Self.fetchAgents(lobby)
        await lobby.disconnect()
        return agents
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

    /// Live agent list: the current agents, then re-yields on `agents_changed` (roots/autonomy
    /// edits) and `fleet_changed` (connect/disconnect).
    public func agentUpdates() async throws -> AsyncStream<[Agent]> {
        let lobby = PhoenixChannel()
        try await lobby.connect(serverURL: endpoint.serverURL, token: endpoint.token, topic: NascEndpoint.lobbyTopic)
        let pushes = lobby.pushes

        return AsyncStream { continuation in
            let task = Task {
                if let list = try? await Self.fetchAgents(lobby) { continuation.yield(list) }
                for await frame in pushes where frame.event == "agents_changed" || frame.event == "fleet_changed" {
                    if let list = try? await Self.fetchAgents(lobby) { continuation.yield(list) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await lobby.disconnect() }
            }
        }
    }

    private static func fetchAgents(_ lobby: PhoenixChannel) async throws -> [Agent] {
        let resp = try await lobby.call(event: "list_agents", payload: [:])
        let arr = resp["agents"] as? [[String: Any]] ?? []
        return arr.compactMap(Agent.from)
    }

    /// Register this device's APNs token so nasc can push it (e.g. on approval needed).
    public func registerDevice(apnsToken: String, env: String = "sandbox", label: String? = nil) async throws {
        let lobby = PhoenixChannel()
        try await lobby.connect(serverURL: endpoint.serverURL, token: endpoint.token, topic: NascEndpoint.lobbyTopic)
        var payload: [String: Any] = ["apns_token": apnsToken, "platform": "ios", "apns_env": env]
        if let label { payload["label"] = label }
        _ = try await lobby.call(event: "register_device", payload: payload)
        await lobby.disconnect()
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

    /// Neural TTS via nasc's `/tts` proxy (croí). Returns WAV audio bytes.
    public func synthesize(_ text: String, voiceID: String = "bf_emma") async throws -> Data {
        let base = endpoint.httpBase.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
            ?? endpoint.httpBase
        guard let url = URL(string: base + "/tts") else { throw ChannelError.invalidURL(base + "/tts") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
