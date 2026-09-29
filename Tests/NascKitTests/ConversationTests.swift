import XCTest

@testable import NascKit

/// Fixtures are wire frames shaped like nasc's `Sessions.serialize_event/1`, decoded the way the app
/// decodes them, plus the local events `SessionModel` appends itself (the `send` echo, the
/// `interrupt` echo, "attach failed", the live `done`). Approval kinds never reach the app's
/// `events` — `SessionModel` keeps them in `pendingApprovals` — so they appear in no sequence here.
final class ConversationTests: XCTestCase {
    // --- decode ---

    func testDecodesNarrationFromAToolCallsMetadata() {
        let e = event(
            #"{"sequence":12,"kind":"tool_call","role":"assistant","content":"read_file","metadata":{"args":{"path":"config.exs"},"raw":"Let me check the config.\n<tool_call>…</tool_call>","adapter":"Ogma.ToolProtocol.Native","narration":"Let me check the config."}}"#
        )

        XCTAssertEqual(e.narration, "Let me check the config.")
    }

    func testAToolCallWithoutNarrationHasNone() {
        XCTAssertNil(toolCall("shell").narration)
        XCTAssertNil(
            event(#"{"sequence":3,"kind":"tool_call","role":"assistant","content":"shell","metadata":{"narration":""}}"#)
                .narration
        )
    }

    func testNarrationIsReadOnlyFromToolCalls() {
        let e = event(
            #"{"sequence":4,"kind":"assistant_msg","role":"assistant","content":"Done.","metadata":{"narration":"stray"}}"#
        )

        XCTAssertNil(e.narration)
    }

    // --- items ---

    func testAReplayedRunReadsAsTheConversationWithItsStepsFolded() {
        let events = [
            runStarted(1),
            userMsg(2, "Why is the build red?"),
            toolCall("read_file", seq: 3, narration: "Let me look at the CI log."),
            toolResult("read_file", seq: 4),
            toolCall("shell", seq: 5),
            toolResult("shell", seq: 6),
            toolCall("edit_file", seq: 7, narration: "A missing import. Fixing it."),
            toolResult("edit_file", seq: 8),
            assistantMsg(9, "Fixed: `Foo` was never imported."),
            statusChange(10, "done"),
        ]

        XCTAssertEqual(
            render(Conversation.items(events)),
            [
                "you: Why is the build red?",
                "agent: Let me look at the CI log.",
                "steps: 2 · shell",
                "agent: A missing import. Fixing it.",
                "steps: 1 · edit_file",
                "agent: Fixed: `Foo` was never imported.",
            ]
        )
    }

    func testTurnsWithoutNarrationStayInOneGroup() {
        let events = [
            userMsg(1, "tidy the imports"),
            toolCall("glob", seq: 2), toolResult("glob", seq: 3),
            toolCall("read_file", seq: 4), toolResult("read_file", seq: 5),
            toolCall("edit_file", seq: 6), toolResult("edit_file", seq: 7),
        ]

        XCTAssertEqual(render(Conversation.items(events)), ["you: tidy the imports", "steps: 3 · edit_file"])
    }

    func testAnErrorRunShowsTheErrorInline() {
        let events = [
            userMsg(1, "deploy it"),
            toolCall("shell", seq: 2), toolResult("shell", seq: 3),
            system(4, "error: inference failed: croí unreachable"),
            statusChange(5, "failed"),
        ]

        XCTAssertEqual(
            render(Conversation.items(events)),
            ["you: deploy it", "steps: 1 · shell", "notice: error: inference failed: croí unreachable"]
        )
    }

    func testTheLocalEchoAndALiveRunFoldLikeAReplay() {
        let events = [
            NascEvent(kind: "user_msg", role: "user", content: "run the tests"),  // SessionModel.sendText
            toolCall("shell", seq: 20, narration: "Running the suite."),
            toolResult("shell", seq: 21),
            assistantMsg(22, "All green."),
            NascEvent.from(frame: InFrame(refID: nil, topic: "session:s", event: "done", payload: ["outcome": "ok"]))!,
        ]

        XCTAssertEqual(
            render(Conversation.items(events)),
            ["you: run the tests", "agent: Running the suite.", "steps: 1 · shell", "agent: All green."]
        )
    }

    func testAFailedAttachIsANotice() {
        let events = [NascEvent(kind: "system", content: "attach failed: The network connection was lost.")]

        XCTAssertEqual(render(Conversation.items(events)), ["notice: attach failed: The network connection was lost."])
    }

    func testAnInterruptIsQueuedUntilTheAgentLogsIt() {
        let sent = [
            userMsg(1, "refactor the parser"),
            toolCall("read_file", seq: 2), toolResult("read_file", seq: 3),
            NascEvent(kind: "interrupt", role: "user", content: "keep the public API"),
        ]
        XCTAssertEqual(
            render(Conversation.items(sent)),
            ["you: refactor the parser", "steps: 1 · read_file", "you (queued): keep the public API"]
        )

        // ogma logs it as a user_msg at its next turn boundary; the echo gives way to it.
        let logged = sent + [
            toolCall("read_file", seq: 4), toolResult("read_file", seq: 5),
            userMsg(6, "keep the public API"),
            toolCall("edit_file", seq: 7), toolResult("edit_file", seq: 8),
        ]
        XCTAssertEqual(
            render(Conversation.items(logged)),
            [
                "you: refactor the parser", "steps: 2 · read_file",
                "you: keep the public API", "steps: 1 · edit_file",
            ]
        )
    }

    func testAnInterruptTheRunNeverTookStaysQueued() {
        let events = [
            userMsg(1, "one"),
            toolCall("shell", seq: 2), toolResult("shell", seq: 3),
            assistantMsg(4, "done"),
            statusChange(5, "done"),
            NascEvent(kind: "interrupt", role: "user", content: "also two"),
        ]

        XCTAssertEqual(render(Conversation.items(events)).last, "you (queued): also two")
    }

    func testEachLoggedMessageAnswersOnlyOneInterrupt() {
        let events = [
            NascEvent(kind: "interrupt", role: "user", content: "stop"),
            NascEvent(kind: "interrupt", role: "user", content: "stop"),
            userMsg(9, "stop"),
        ]

        XCTAssertEqual(render(Conversation.items(events)), ["you (queued): stop", "you: stop"])

        // The same guidance sent twice and taken twice: each logged copy answers its own echo.
        XCTAssertEqual(render(Conversation.items(events + [userMsg(10, "stop")])), ["you: stop", "you: stop"])
    }

    func testTheLocalSendEchoNeverAnswersAnInterrupt() {
        let events = [
            NascEvent(kind: "interrupt", role: "user", content: "wait"),
            NascEvent(kind: "user_msg", role: "user", content: "wait"),
        ]

        XCTAssertEqual(render(Conversation.items(events)), ["you (queued): wait", "you: wait"])
    }

    func testAMessageThatNeverReachedNascSaysSo() {
        let events = [
            userMsg(1, "status?"),
            assistantMsg(2, "Idle."),
            NascEvent(kind: "unsent", role: "user", content: "run it again"),  // SessionModel: prompt threw
        ]

        XCTAssertEqual(render(Conversation.items(events)), ["you: status?", "agent: Idle.", "you (not sent): run it again"])
    }

    func testIdsAreUniqueAndAGrowingGroupKeepsItsID() {
        let first = toolCall("read_file", seq: 2, narration: "Reading.")
        let before = Conversation.items([userMsg(1, "go"), first, toolResult("read_file", seq: 3)])
        let after = Conversation.items(
            [userMsg(1, "go"), first, toolResult("read_file", seq: 3), toolCall("shell", seq: 4)]
        )

        let ids = after.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(before.last?.id, after.last?.id)
        guard case let .steps(steps)? = after.last else { return XCTFail("expected a steps group") }
        XCTAssertEqual(steps.toolCount, 2)
        XCTAssertEqual(steps.lastTool, "shell")
    }

    func testNothingIsShownForAnEmptySession() {
        XCTAssertTrue(Conversation.items([]).isEmpty)
        XCTAssertTrue(Conversation.items([runStarted(1), statusChange(2, "done")]).isEmpty)
    }

    // --- merge (live events and a reconnect's full replay into what's on screen) ---

    func testALiveEventIsAppended() {
        let held = [userMsg(1, "go"), toolCall("shell", seq: 2)]
        XCTAssertEqual(sequences(Conversation.merge(toolResult("shell", seq: 3), into: held)), [1, 2, 3])
    }

    func testAReplayedEventAlreadyOnScreenIsDropped() {
        let held = [userMsg(1, "go"), toolCall("shell", seq: 2)]
        XCTAssertNil(Conversation.merge(toolCall("shell", seq: 2), into: held))
    }

    func testAReconnectFillsInWhatWasMissedInOrderAndKeepsLocalEchoes() {
        // Seen live: the agent's events (user_msg and run markers are never broadcast live), the
        // phone's own echo, and a later interrupt echo the agent hasn't taken yet.
        var held: [NascEvent] = [
            NascEvent(kind: "user_msg", role: "user", content: "fix it"),
            toolCall("shell", seq: 3, narration: "Looking."),
            toolResult("shell", seq: 4),
            NascEvent(kind: "interrupt", role: "user", content: "and add a test"),
        ]
        // The replay after reconnecting: the whole log, then what happened while away.
        let replay = [
            runStarted(1), userMsg(2, "fix it"), toolCall("shell", seq: 3, narration: "Looking."),
            toolResult("shell", seq: 4), userMsg(5, "and add a test"), toolCall("edit_file", seq: 6),
            toolResult("edit_file", seq: 7), assistantMsg(8, "Fixed, with a test."), statusChange(9, "done"),
        ]
        for event in replay {
            if let merged = Conversation.merge(event, into: held) { held = merged }
        }

        XCTAssertEqual(held.compactMap(\.sequence), [1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(
            render(Conversation.items(held)),
            [
                "you: fix it", "agent: Looking.", "steps: 1 · shell",
                "you: and add a test", "steps: 1 · edit_file", "agent: Fixed, with a test.",
            ]
        )
    }

    func testAnUnsentMessageStaysWhereItWasTyped() {
        var held: [NascEvent] = [
            userMsg(1, "first"), assistantMsg(2, "ok"),
            NascEvent(kind: "unsent", role: "user", content: "second"),
        ]
        for event in [userMsg(1, "first"), assistantMsg(2, "ok"), userMsg(3, "third"), assistantMsg(4, "done")] {
            if let merged = Conversation.merge(event, into: held) { held = merged }
        }

        XCTAssertEqual(
            render(Conversation.items(held)),
            ["you: first", "agent: ok", "you (not sent): second", "you: third", "agent: done"]
        )
    }

    func testTheLoggedCopyReplacesOnlyOneMatchingEcho() {
        let held = [
            NascEvent(kind: "user_msg", role: "user", content: "again"),
            NascEvent(kind: "user_msg", role: "user", content: "again"),
        ]
        let merged = Conversation.merge(userMsg(7, "again"), into: held)

        XCTAssertEqual(merged?.map { $0.sequence ?? -1 }, [7, -1])
    }

    func testEventsWithoutASequenceAreAlwaysAppended() {
        let held = [userMsg(1, "go")]
        let done = NascEvent.from(frame: InFrame(refID: nil, topic: "session:s", event: "done", payload: [:]))!

        XCTAssertEqual(Conversation.merge(done, into: held)?.map(\.kind), ["user_msg", "done"])
    }

    // --- helpers ---

    private func sequences(_ events: [NascEvent]?) -> [Int] { events?.compactMap(\.sequence) ?? [] }

    private func render(_ items: [ConversationItem]) -> [String] {
        items.map { item in
            switch item {
            case let .user(event, delivery):
                let mark = [.queued: " (queued)", .unsent: " (not sent)"][delivery] ?? ""
                return "you\(mark): \(event.content ?? "")"
            case let .agent(_, text): return "agent: \(text)"
            case let .notice(event): return "notice: \(event.content ?? "")"
            case let .steps(steps): return "steps: \(steps.toolCount) · \(steps.lastTool ?? "")"
            }
        }
    }

    private func event(_ json: String) -> NascEvent {
        let payload = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return NascEvent.from(frame: InFrame(refID: nil, topic: "session:s", event: "event", payload: payload))!
    }

    private func frame(_ seq: Int, _ kind: String, role: String?, content: String?, metadata: [String: Any] = [:]) -> NascEvent {
        var payload: [String: Any] = ["sequence": seq, "kind": kind, "metadata": metadata]
        payload["role"] = role
        payload["content"] = content
        return NascEvent.from(frame: InFrame(refID: nil, topic: "session:s", event: "event", payload: payload))!
    }

    private func runStarted(_ seq: Int) -> NascEvent {
        frame(seq, "run_started", role: nil, content: nil, metadata: ["project": "nasc"])
    }

    private func userMsg(_ seq: Int, _ text: String) -> NascEvent { frame(seq, "user_msg", role: "user", content: text) }

    private func assistantMsg(_ seq: Int, _ text: String) -> NascEvent {
        frame(seq, "assistant_msg", role: "assistant", content: text, metadata: ["adapter": "Ogma.ToolProtocol.Native"])
    }

    private func toolCall(_ name: String, seq: Int = 1, narration: String? = nil) -> NascEvent {
        var meta: [String: Any] = ["args": [:], "raw": NSNull(), "adapter": "Ogma.ToolProtocol.Native"]
        meta["narration"] = narration
        return frame(seq, "tool_call", role: "assistant", content: name, metadata: meta)
    }

    private func toolResult(_ name: String, seq: Int) -> NascEvent {
        frame(seq, "tool_result", role: "tool", content: "ok", metadata: ["tool": name])
    }

    private func system(_ seq: Int, _ reason: String) -> NascEvent { frame(seq, "system", role: nil, content: reason) }

    private func statusChange(_ seq: Int, _ status: String) -> NascEvent {
        frame(seq, "status_change", role: nil, content: status, metadata: ["usage": [:], "outcome": status == "done" ? "ok" : "error"])
    }
}
