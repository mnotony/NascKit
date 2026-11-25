import XCTest

@testable import NascKit

final class ApprovalTests: XCTestCase {
    // --- Approval.from (metadata parsing) ---

    func testParsesToolApprovalWithFullContract() {
        let meta: [String: Any] = [
            "request_id": "appr-1",
            "type": "tool_approval",
            "tool": "shell",
            "summary": "mix ecto.reset",
            "reason": "a shell command outside the auto-run allowlist",
            "severity": "consequential",
            "expires_at": "2026-09-01T09:43:12Z",
        ]

        let a = Approval.from(content: "Run a shell command", metadata: meta)
        XCTAssertEqual(a?.requestID, "appr-1")
        XCTAssertNotNil(a?.expiresAt)
        XCTAssertEqual(
            a?.kind,
            .tool(
                tool: "shell",
                summary: "mix ecto.reset",
                reason: "a shell command outside the auto-run allowlist",
                severity: "consequential"
            )
        )
    }

    func testParsesReauth() {
        let meta: [String: Any] = [
            "request_id": "reauth-9",
            "type": "reauth",
            "service": "searchlink",
            "reason": "vpn_down",
            "expires_at": "2026-09-01T09:53:00Z",
        ]

        let a = Approval.from(content: "Re-authenticate searchlink", metadata: meta)
        XCTAssertEqual(a?.kind, .reauth(service: "searchlink"))
        XCTAssertNotNil(a?.expiresAt)
    }

    func testFallsBackToPreContractShape() {
        // Old agents put the bare tool name in `content` with no `type`.
        let meta: [String: Any] = ["request_id": "appr-2", "args": ["command": "git push"]]

        let a = Approval.from(content: "shell", metadata: meta)
        XCTAssertEqual(a?.kind, .unknown(title: "shell"))
        XCTAssertNil(a?.expiresAt)
    }

    func testNilWithoutRequestID() {
        XCTAssertNil(Approval.from(content: "x", metadata: [:]))
        XCTAssertNil(Approval.from(content: "x", metadata: nil))
    }

    func testParsesTimestampWithMicroseconds() {
        // Elixir's DateTime.to_iso8601 for :utc_datetime_usec includes 6 fractional digits.
        XCTAssertNotNil(Approval.parseTimestamp("2026-09-01T19:25:55.042354Z"))
        XCTAssertNotNil(Approval.parseTimestamp("2026-09-01T19:25:55Z"))
        XCTAssertNil(Approval.parseTimestamp("not-a-date"))
    }

    // --- NascEvent.from (the wire → model mapping) ---

    func testNascEventParsesInputRequestedFromFrame() throws {
        let json = """
            ["1","2","session:abc","event",{"kind":"input_requested","content":"Run a shell command",\
            "metadata":{"request_id":"appr-1","type":"tool_approval","tool":"shell","summary":"whoami",\
            "reason":"a shell command outside the auto-run allowlist","severity":"consequential",\
            "expires_at":"2026-09-01T09:43:12Z"}}]
            """
        let ev = NascEvent.from(frame: try InFrame.parse(json))

        XCTAssertEqual(ev?.kind, "input_requested")
        XCTAssertEqual(ev?.requestID, "appr-1")
        guard case .tool(let tool, let summary, _, let severity)? = ev?.approval?.kind else {
            return XCTFail("expected a tool approval")
        }
        XCTAssertEqual(tool, "shell")
        XCTAssertEqual(summary, "whoami")
        XCTAssertEqual(severity, "consequential")
    }

    func testNascEventParsesInputProvidedOutcome() throws {
        let json = """
            [null,"3","session:abc","event",{"kind":"input_provided","content":"approve",\
            "metadata":{"request_id":"appr-1","outcome":"approve"}}]
            """
        let ev = NascEvent.from(frame: try InFrame.parse(json))

        XCTAssertEqual(ev?.kind, "input_provided")
        XCTAssertEqual(ev?.outcome, "approve")
        XCTAssertNil(ev?.approval, "input_provided carries no approval payload")
    }

    // --- discuss and suggestions (nasc docs/plans/approval-choices.md) ---

    func testDiscussIsReadExactlyAndNeverForAReauth() {
        func parse(_ extra: [String: Any]) -> Approval? {
            var meta: [String: Any] = ["request_id": "r", "type": "tool_approval", "tool": "shell"]
            meta.merge(extra) { $1 }
            return Approval.from(content: nil, metadata: meta)
        }
        XCTAssertEqual(parse(["discuss": true])?.discuss, true)
        XCTAssertEqual(parse(["discuss": "true"])?.discuss, false)
        XCTAssertEqual(parse(["discuss": 1])?.discuss, false)
        // as JSON delivers it: a boolean, not a number
        let json = try? JSONSerialization.jsonObject(with: Data(#"{"discuss": true, "one": 1}"#.utf8)) as? [String: Any]
        XCTAssertEqual(parse(["discuss": json?["discuss"] as Any])?.discuss, true)
        XCTAssertEqual(parse(["discuss": json?["one"] as Any])?.discuss, false)
        XCTAssertEqual(parse([:])?.discuss, false)
        XCTAssertEqual(parse(["type": "reauth", "discuss": true])?.discuss, false)
    }

    func testSuggestionsAreCleanedAgainAndTwoAtMost() {
        let meta: [String: Any] = [
            "request_id": "r", "type": "tool_approval", "tool": "shell",
            "suggestions": ["\u{1b}[31mDelete only build/tmp\u{1b}[0m", "Yes", 7, "List\u{202e} build/ first", "Read it"],
        ]
        XCTAssertEqual(
            Approval.from(content: nil, metadata: meta)?.suggestions,
            ["Delete only build/tmp", "List build/ first"]
        )
        let reauth: [String: Any] = ["request_id": "r", "type": "reauth", "suggestions": ["x"]]
        XCTAssertEqual(Approval.from(content: nil, metadata: reauth)?.suggestions, [])
    }

    // The same table as ogma's (test/ogma/suggestions_test.exs) and nasc's: the copies can't drift.
    func testTheCleaningRule() {
        let kept: [(String, String)] = [
            ("\u{1b}[31mList\u{1b}[0m", "List"),
            ("List\u{9b}31mit", "Listit"),
            ("List\u{202e}it", "Listit"),
            ("List\u{200b}it", "Listit"),
            ("List\u{2028}it", "List it"),
            ("List\tfiles", "List files"),
            ("a\u{85}b", "a b"),
            ("\u{2714}\u{fe0f} done", "\u{2714} done"),
            ("  spaced   out  ", "spaced out"),
            ("- 1. ❯ List it", "List it"),
            ("› first", "first"),
            ("2) first", "first"),
            ("--dry-run first", "--dry-run first"),
            ("2 files only", "2 files only"),
            ("Yesterday's log first", "Yesterday's log first"),
            ("Run it with --dry-run first", "Run it with --dry-run first"),
            ("Proceed without the migration", "Proceed without the migration"),
            ("Approvers list first", "Approvers list first"),
            ("café e\u{301}\u{302} ok", "café e\u{301}\u{302} ok"),
            ("Use the — longer path… 日本語 😀", "Use the — longer path… 日本語 😀"),
            // escapes as ogma removes them: OSC whole, a two-byte ESC sequence whole
            ("\u{1b}]8;;http://x\u{7}link\u{1b}]8;;\u{7}", "link"),
            ("a\u{1b}Mb", "ab"),
            ("approve_x list", "approve_x list"),
            ("١. first", "first"),
            ("List  \u{301}it", "List \u{301}it"),
        ]
        for (input, want) in kept {
            XCTAssertEqual(Suggestions.clean([input]), [want], input.debugDescription)
        }
        let dropped = [
            "Go ahead and run it", "Yes", "yes, go on", "Approve it", "Approved, run it", "Run it.",
            "Run it .", "proceed", "Chat about this", "Chat about this call",
            "Tell it what to do instead (esc to refuse)", "Check logs ❯ first",
            "remember: always use staging", " remember: x", "Forget: the old path", "", "   ",
            "Yes\u{fe00}", "Go ahead\u{e0100}", "Zalgo e\u{301}\u{302}\u{303} text",
            String(repeating: "a", count: 81),
            "YEſ", "Run it ~",
            // by scalar, as ogma: a mark after the word, or after a label, is no disguise
            "Yes\u{20dd}", "Go ahead\u{20dd}", "Tell it what to do instead\u{301}", "Chat about this\u{301} call",
            "remember:\u{301} x", "Check logs ❯\u{301} first",
        ]
        for input in dropped {
            XCTAssertEqual(Suggestions.clean([input]), [], input.debugDescription)
        }
        XCTAssertEqual(Suggestions.clean([String(repeating: "a", count: 80)]).count, 1)
        XCTAssertEqual(
            Suggestions.clean(["- List it", "list IT", "Read it", "Grep it"]),
            ["List it", "Read it"]
        )
        // composed and decomposed are two strings to ogma, so two buttons here too
        XCTAssertEqual(Suggestions.clean(["Use caf\u{e9}", "Use cafe\u{301}", "Third"]).count, 2)
        XCTAssertEqual(Suggestions.clean(["Use caf\u{e9}", "Use cafe\u{301}"]), ["Use caf\u{e9}", "Use cafe\u{301}"])
    }
}

