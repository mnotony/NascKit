import Foundation

/// A fleet agent with its live + persisted state — the Agents screen row. `roots` are the base
/// dirs it resolves a project to (`<root>/<project>`); `autonomous` means its runs auto-approve
/// safe tool calls (and only pause + notify on consequential ones).
public struct Agent: Sendable, Identifiable, Hashable {
    public let id: String
    public let online: Bool
    public let capabilities: [String]
    public let roots: [String]
    public let autonomous: Bool

    public init(
        id: String,
        online: Bool,
        capabilities: [String] = [],
        roots: [String] = [],
        autonomous: Bool = false
    ) {
        self.id = id
        self.online = online
        self.capabilities = capabilities
        self.roots = roots
        self.autonomous = autonomous
    }

    static func from(_ dict: [String: Any]) -> Agent? {
        guard let id = dict["id"] as? String else { return nil }
        return Agent(
            id: id,
            online: dict["online"] as? Bool ?? false,
            capabilities: dict["capabilities"] as? [String] ?? [],
            roots: dict["roots"] as? [String] ?? [],
            autonomous: dict["autonomous"] as? Bool ?? false
        )
    }
}
