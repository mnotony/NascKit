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
}
