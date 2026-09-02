import Foundation

/// A session in the list (from the lobby's `list_sessions`).
public struct SessionSummary: Sendable, Identifiable, Hashable {
    public let id: String
    public let slug: String
    /// Persisted lifecycle status: `active` / `suspended` / `ended`.
    public let status: String?
    public let title: String?
    /// Live run-state: `running` / `awaiting_input` / `interrupted` / `idle` (see protocol lobby).
    public let runState: String?

    public init(
        id: String,
        slug: String,
        status: String? = nil,
        title: String? = nil,
        runState: String? = nil
    ) {
        self.id = id
        self.slug = slug
        self.status = status
        self.title = title
        self.runState = runState
    }
}

/// A session event as seen by a client: a durable `event` (assistant_msg, tool_call,
/// tool_result, input_requested, input_provided, user_msg, status_change), a streaming
/// `token`, or `done`.
public struct NascEvent: Sendable, Identifiable {
    public let id: UUID
    public let kind: String
    public let role: String?
    public let content: String?
    public let sequence: Int?
    public let requestID: String?
    /// The parsed request when `kind == "input_requested"`, else `nil`.
    public let approval: Approval?
    /// The resolution (`approve` | `deny` | `expired`) when `kind == "input_provided"`, else `nil`.
    public let outcome: String?

    public init(
        id: UUID = UUID(),
        kind: String,
        role: String? = nil,
        content: String? = nil,
        sequence: Int? = nil,
        requestID: String? = nil,
        approval: Approval? = nil,
        outcome: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.role = role
        self.content = content
        self.sequence = sequence
        self.requestID = requestID
        self.approval = approval
        self.outcome = outcome
    }

    static func from(frame: InFrame) -> NascEvent? {
        let p = frame.payload

        switch frame.event {
        case "event":
            let kind = p["kind"] as? String ?? "event"
            let meta = p["metadata"] as? [String: Any]
            return NascEvent(
                kind: kind,
                role: p["role"] as? String,
                content: p["content"] as? String,
                sequence: p["sequence"] as? Int,
                requestID: meta?["request_id"] as? String,
                approval: kind == "input_requested"
                    ? Approval.from(content: p["content"] as? String, metadata: meta)
                    : nil,
                outcome: kind == "input_provided" ? meta?["outcome"] as? String : nil
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
