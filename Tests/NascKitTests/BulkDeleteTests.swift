import XCTest

@testable import NascKit

final class BulkDeleteTests: XCTestCase {
    // --- NascClient.deleteEach (the bulk-delete loop's failure rules) ---

    /// A listing in which every id is still present — a failure stays a failure.
    private func allListed(_ ids: [String]) -> () async throws -> Set<String> { { Set(ids) } }

    func testAllDeletedReturnsNoFailures() async {
        var attempted: [String] = []
        let failed = await NascClient.deleteEach(["a", "b", "c"], listed: allListed(["a", "b", "c"])) { attempted.append($0) }
        XCTAssertEqual(failed, [])
        XCTAssertEqual(attempted, ["a", "b", "c"])
    }

    func testEmptyInputMakesNoCalls() async {
        var attempted: [String] = []
        let failed = await NascClient.deleteEach([], listed: allListed([])) { attempted.append($0) }
        XCTAssertEqual(failed, [])
        XCTAssertEqual(attempted, [])
    }

    func testServerRefusalFailsThatIdAndContinues() async {
        var attempted: [String] = []
        let failed = await NascClient.deleteEach(["a", "b", "c"], listed: allListed(["a", "b", "c"])) { id in
            attempted.append(id)
            if id == "b" { throw ChannelError.callFailed("delete failed") }
        }
        XCTAssertEqual(failed, ["b"])
        XCTAssertEqual(attempted, ["a", "b", "c"])
    }

    func testTimeoutFailsTheRestWithoutTryingThem() async {
        var attempted: [String] = []
        let failed = await NascClient.deleteEach(["a", "b", "c", "d"], listed: allListed(["a", "b", "c", "d"])) { id in
            attempted.append(id)
            if id == "b" { throw ChannelError.timeout }
        }
        XCTAssertEqual(failed, ["b", "c", "d"])
        XCTAssertEqual(attempted, ["a", "b"])
    }

    func testDisconnectFailsTheRestWithoutTryingThem() async {
        var attempted: [String] = []
        let failed = await NascClient.deleteEach(["a", "b", "c"], listed: allListed(["a", "b", "c"])) { id in
            attempted.append(id)
            if id == "a" { throw ChannelError.disconnected }
        }
        XCTAssertEqual(failed, ["a", "b", "c"])
        XCTAssertEqual(attempted, ["a"])
    }

    func testSendFailureFailsTheRest() async {
        var attempted: [String] = []
        let failed = await NascClient.deleteEach(["a", "b", "c"], listed: allListed(["a", "b", "c"])) { id in
            attempted.append(id)
            if id == "b" { throw URLError(.networkConnectionLost) }
        }
        XCTAssertEqual(failed, ["b", "c"])
        XCTAssertEqual(attempted, ["a", "b"])
    }

    func testRefusalThenDropKeepsBoth() async {
        let failed = await NascClient.deleteEach(["a", "b", "c", "d"], listed: allListed(["a", "b", "c", "d"])) { id in
            if id == "a" { throw ChannelError.callFailed("delete failed") }
            if id == "c" { throw ChannelError.disconnected }
        }
        XCTAssertEqual(failed, ["a", "c", "d"])
    }

    // --- a failure that is no longer listed was deleted (archived elsewhere, or before a timeout) ---

    func testRefusedIdNoLongerListedCountsAsDeleted() async {
        // nasc refuses to delete an already-archived session ("delete failed", same as a real
        // failure); it is gone from the list, so it is not a failure.
        let failed = await NascClient.deleteEach(["a", "b", "c"], listed: { ["c"] }) { id in
            if id == "b" || id == "c" { throw ChannelError.callFailed("delete failed") }
        }
        XCTAssertEqual(failed, ["c"])
    }

    func testTimedOutDeleteThatLandedCountsAsDeletedButUntriedStay() async {
        let failed = await NascClient.deleteEach(["a", "b", "c"], listed: { ["c"] }) { id in
            if id == "b" { throw ChannelError.timeout }
        }
        XCTAssertEqual(failed, ["c"])
    }

    func testListingFailureKeepsEveryFailure() async {
        let failed = await NascClient.deleteEach(["a", "b", "c"], listed: { throw ChannelError.disconnected }) { id in
            if id == "a" { throw ChannelError.disconnected }
        }
        XCTAssertEqual(failed, ["a", "b", "c"])
    }

    func testNoFailuresSkipsTheListing() async {
        var listed = false
        let failed = await NascClient.deleteEach(["a", "b"], listed: { listed = true; return [] }) { _ in }
        XCTAssertEqual(failed, [])
        XCTAssertFalse(listed)
    }

    // --- SessionSummary.isLive (nasc's run_state: running | awaiting_input | failed | interrupted
    // | idle — session_server.ex `run_state/1`; only the first two are a run in progress) ---

    func testLiveRunStates() {
        XCTAssertTrue(SessionSummary(id: "s", slug: "s", runState: "running").isLive)
        XCTAssertTrue(SessionSummary(id: "s", slug: "s", runState: "awaiting_input").isLive)
    }

    func testFinishedRunStatesAreNotLive() {
        for state in ["idle", "interrupted", "failed", nil] {
            XCTAssertFalse(SessionSummary(id: "s", slug: "s", runState: state).isLive, "\(state ?? "nil")")
        }
    }
}
