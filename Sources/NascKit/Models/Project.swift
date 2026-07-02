import Foundation

/// A project the user can start a session on — the picker source. `name` is the routing key
/// (nasc maps it to a required `capability`, so the session lands on an agent that can reach it);
/// `capability` is what that agent must advertise (nil = no special requirement).
public struct Project: Sendable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let capability: String?
    public let title: String?

    public init(name: String, capability: String? = nil, title: String? = nil) {
        self.name = name
        self.capability = capability
        self.title = title
    }

    /// A friendly label for the picker.
    public var displayName: String { title ?? name }
}
