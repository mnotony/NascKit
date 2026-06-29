import Foundation

/// A snapshot of a server's fleet: connected agents + a session-status summary.
public struct FleetStatus: Sendable {
    public struct Agent: Sendable, Identifiable {
        public let id: String
        public let connectedAt: Int?
    }

    public let agents: [Agent]
    public let sessionCount: Int
    public let sessionsByStatus: [String: Int]

    static func from(_ payload: [String: Any]) -> FleetStatus {
        let agents = (payload["agents"] as? [[String: Any]] ?? []).map {
            Agent(id: $0["agent_id"] as? String ?? "?", connectedAt: $0["connected_at"] as? Int)
        }

        return FleetStatus(
            agents: agents,
            sessionCount: payload["session_count"] as? Int ?? 0,
            sessionsByStatus: payload["sessions_by_status"] as? [String: Int] ?? [:]
        )
    }
}
