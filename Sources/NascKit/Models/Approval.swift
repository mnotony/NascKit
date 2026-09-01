import Foundation

/// A parsed `input_requested` event — what the human is being asked to decide.
///
/// Mirrors the agent-side contract (ogma `NascClient`): a dangerous tool call, a VPN re-auth, or
/// a pre-contract shape we still render gracefully. Resolved by the matching `input_provided`.
public struct Approval: Sendable, Equatable, Identifiable {
    public var id: String { requestID }
    public let requestID: String
    public let kind: ApprovalKind
    /// Deadline after which the server resolves the request as `expired`.
    public let expiresAt: Date?

    public init(requestID: String, kind: ApprovalKind, expiresAt: Date? = nil) {
        self.requestID = requestID
        self.kind = kind
        self.expiresAt = expiresAt
    }
}

public enum ApprovalKind: Sendable, Equatable {
    /// A dangerous tool call awaiting approval.
    case tool(tool: String, summary: String, reason: String, severity: String)
    /// A run blocked on a VPN re-auth. Approving means "I've re-authed, retry".
    case reauth(service: String)
    /// A pre-contract or otherwise unrecognized shape — fall back to a title from `content`.
    case unknown(title: String)
}

extension Approval {
    /// Parse the `content` + `metadata` of an `input_requested` event. `nil` without a `request_id`.
    static func from(content: String?, metadata: [String: Any]?) -> Approval? {
        guard let meta = metadata, let requestID = meta["request_id"] as? String else { return nil }
        let expiresAt = (meta["expires_at"] as? String).flatMap(parseTimestamp)

        let kind: ApprovalKind
        switch meta["type"] as? String {
        case "reauth":
            kind = .reauth(service: meta["service"] as? String ?? "service")
        case "tool_approval":
            kind = .tool(
                tool: meta["tool"] as? String ?? "a tool",
                summary: meta["summary"] as? String ?? "",
                reason: meta["reason"] as? String ?? "",
                severity: meta["severity"] as? String ?? ""
            )
        default:
            // Pre-contract shape: the tool name was the event `content`.
            kind = .unknown(title: content ?? "a tool call")
        }

        return Approval(requestID: requestID, kind: kind, expiresAt: expiresAt)
    }

    /// nasc emits ISO-8601 UTC timestamps with microseconds; accept them with or without a
    /// fractional-seconds component.
    static func parseTimestamp(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: s) { return date }
        return ISO8601DateFormatter().date(from: s)
    }
}
