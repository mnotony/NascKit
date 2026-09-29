import Foundation

/// One entry in a session read as a conversation: what was said, with the agent's work between
/// messages folded into counted steps.
public enum ConversationItem: Identifiable, Sendable {
    /// Something the user said, and whether it got there.
    case user(NascEvent, Delivery)
    /// Something the agent said: a final `assistant_msg`, or the narration that opened a tool turn.
    case agent(id: String, text: String)
    /// A `system` line — an agent error, a failed attach.
    case notice(NascEvent)
    /// The work between two of the above; only emitted when it holds at least one tool call.
    case steps(Steps)

    public var id: String {
        switch self {
        case let .user(event, _): return "user-\(event.id)"
        case let .agent(id, _): return id
        case let .notice(event): return "notice-\(event.id)"
        case let .steps(steps): return steps.id
        }
    }
}

/// Where a user message stands.
public enum Delivery: Sendable, Equatable {
    /// Logged by nasc, or sent (a prompt's local echo — nasc logs it on dispatch).
    case sent
    /// A client-local `interrupt` echo the agent has not logged yet; it takes guidance at its next
    /// turn boundary.
    case queued
    /// A client-local `unsent` echo: the prompt or interrupt never reached nasc.
    case unsent
}

/// A run of background events (tool calls, their results, run markers) between two conversation
/// entries. Its id is its first event's, so a group keeps its identity while it grows.
public struct Steps: Sendable {
    public let events: [NascEvent]

    public var id: String { "steps-\(events[0].id)" }
    public var toolCount: Int { events.filter { $0.kind == "tool_call" }.count }
    public var lastTool: String? { events.last { $0.kind == "tool_call" }?.content }
}

public enum Conversation {
    /// Project a session's events into conversation items. `events` is what a client holds: the
    /// replayed log, live durable events, and its own local echoes, which never go on the wire — a
    /// `user_msg` without a sequence (a sent prompt), `interrupt` (guidance sent mid-run) and
    /// `unsent` (either one, when sending failed).
    public static func items(_ events: [NascEvent]) -> [ConversationItem] {
        let answered = answeredInterrupts(events)
        var items: [ConversationItem] = []
        var group: [NascEvent] = []

        func flush() {
            if group.contains(where: { $0.kind == "tool_call" }) { items.append(.steps(Steps(events: group))) }
            group = []
        }

        for event in events {
            switch event.kind {
            case "user_msg":
                flush()
                items.append(.user(event, .sent))
            case "interrupt":
                guard !answered.contains(event.id) else { continue }
                flush()
                items.append(.user(event, .queued))
            case "unsent":
                flush()
                items.append(.user(event, .unsent))
            case "assistant_msg":
                flush()
                items.append(.agent(id: "agent-\(event.id)", text: event.content ?? ""))
            case "system":
                flush()
                items.append(.notice(event))
            case "tool_call":
                if let narration = event.narration {
                    flush()
                    items.append(.agent(id: "agent-\(event.id)", text: narration))
                }
                group.append(event)
            default:
                group.append(event)
            }
        }
        flush()
        return items
    }

    /// Interrupt echoes the agent has since logged: each logged `user_msg` (one with a sequence — a
    /// local echo has none) answers the earliest still-open interrupt with the same text.
    private static func answeredInterrupts(_ events: [NascEvent]) -> Set<UUID> {
        var open: [NascEvent] = []
        var answered: Set<UUID> = []
        for event in events {
            if event.kind == "interrupt" {
                open.append(event)
            } else if event.kind == "user_msg", event.sequence != nil,
                let i = open.firstIndex(where: { same($0.content, event.content) }) {
                answered.insert(open.remove(at: i).id)
            }
        }
        return answered
    }

    private static func same(_ a: String?, _ b: String?) -> Bool {
        a?.trimmingCharacters(in: .whitespacesAndNewlines) == b?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
