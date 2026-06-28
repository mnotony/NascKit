import Foundation

/// A session in the list (from the lobby's `list_sessions`).
public struct SessionSummary: Sendable, Identifiable, Hashable {
    public let id: String
    public let slug: String
    public let status: String?
    public let title: String?

    public init(id: String, slug: String, status: String? = nil, title: String? = nil) {
        self.id = id
        self.slug = slug
        self.status = status
        self.title = title
    }
}

/// A session event as seen by a client: a durable `event` (assistant_msg, tool_call,
/// tool_result, input_requested, user_msg, status_change), a streaming `token`, or
/// `done`.
public struct NascEvent: Sendable, Identifiable {
    public let id: UUID
    public let kind: String
    public let role: String?
    public let content: String?
    public let sequence: Int?
    public let requestID: String?

    public init(
        id: UUID = UUID(),
        kind: String,
        role: String? = nil,
        content: String? = nil,
        sequence: Int? = nil,
        requestID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.role = role
        self.content = content
        self.sequence = sequence
        self.requestID = requestID
    }

    static func from(frame: InFrame) -> NascEvent? {
        let p = frame.payload

        switch frame.event {
        case "event":
            let meta = p["metadata"] as? [String: Any]
            return NascEvent(
                kind: p["kind"] as? String ?? "event",
                role: p["role"] as? String,
                content: p["content"] as? String,
                sequence: p["sequence"] as? Int,
                requestID: meta?["request_id"] as? String
            )

        case "token":
            return NascEvent(kind: "token", content: p["delta"] as? String)

        case "done":
            return NascEvent(kind: "done")

        default:
            return nil
        }
    }
}
