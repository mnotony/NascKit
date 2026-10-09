import Foundation
import XCTest

@testable import NascKit

/// `PhoenixChannel` against a real WebSocket (an in-process stub on loopback).
final class PhoenixChannelTests: XCTestCase {
    private var stub: PhoenixStub!

    override func setUp() async throws {
        stub = try PhoenixStub()
        try await stub.start()
    }

    override func tearDown() async throws {
        stub.stop()
    }

    // --- connect ---

    func testJoinNeverAnsweredTimesOutAndClosesTheSocket() async {
        stub.join = .ignore
        let channel = PhoenixChannel(joinTimeout: .milliseconds(300))
        let start = ContinuousClock.now
        do {
            try await within(.seconds(3)) { try await channel.connect(serverURL: self.stub.url, credential: "", topic: "lobby") }
            XCTFail("connect should time out")
        } catch {
            guard case ChannelError.timeout = error else { return XCTFail("expected timeout, got \(error)") }
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        let closed = await stub.eventually { self.stub.closedCount == 1 }
        XCTAssertTrue(closed, "a timed-out connect must close its socket")
    }

    func testJoinThatCantEvenBeSentStillTimesOut() async throws {
        let silent = try SilentServer()
        try await silent.start()
        defer { silent.stop() }
        let channel = PhoenixChannel(joinTimeout: .milliseconds(300))
        do {
            try await within(.seconds(3)) { try await channel.connect(serverURL: silent.url, credential: "", topic: "lobby") }
            XCTFail("connect should time out")
        } catch {
            guard case ChannelError.timeout = error else { return XCTFail("expected timeout, got \(error)") }
        }
    }

    func testRefusedUpgradeReadsAsARefusedCredential() async throws {
        let server = try SilentServer(refuseWith: 403)
        try await server.start()
        defer { server.stop() }
        let channel = PhoenixChannel()
        do {
            try await within(.seconds(3)) { try await channel.connect(serverURL: server.url, credential: "revoked", topic: "lobby") }
            XCTFail("connect should be refused")
        } catch {
            guard case ChannelError.joinFailed(let reason) = error else { return XCTFail("expected joinFailed, got \(error)") }
            XCTAssertTrue(reason.contains("403"), reason)
        }
    }

    func testCancellingAConnectClosesItsSocketAtOnce() async throws {
        stub.join = .ignore
        let channel = PhoenixChannel(joinTimeout: .seconds(10))
        let url = stub.url
        let connecting = Task { try await channel.connect(serverURL: url, credential: "", topic: "lobby") }
        let joined = await stub.eventually { self.stub.joinsSeen == 1 }
        XCTAssertTrue(joined)
        connecting.cancel()
        let closed = await stub.eventually(.seconds(2)) { self.stub.closedCount == 1 }
        XCTAssertTrue(closed, "a cancelled connect must not wait out its deadline")
        do {
            try await connecting.value
            XCTFail("a cancelled connect should throw")
        } catch {}
    }

    func testRefusedJoinThrowsJoinFailedAndClosesTheSocket() async {
        stub.join = .refuse
        let channel = PhoenixChannel()
        do {
            try await within(.seconds(3)) { try await channel.connect(serverURL: self.stub.url, credential: "", topic: "lobby") }
            XCTFail("connect should be refused")
        } catch {
            guard case ChannelError.joinFailed(let reason) = error else { return XCTFail("expected joinFailed, got \(error)") }
            XCTAssertEqual(reason, "unauthorized")
        }
        let closed = await stub.eventually { self.stub.closedCount == 1 }
        XCTAssertTrue(closed, "a refused connect must close its socket")
    }

    func testAnsweredJoinAndCall() async throws {
        stub.replies = ["list_sessions": ["sessions": [["id": "s1", "slug": "one"]]]]
        let channel = PhoenixChannel()
        try await channel.connect(serverURL: stub.url, credential: "", topic: "lobby")
        let isConnected = await channel.isConnected
        XCTAssertTrue(isConnected)
        let response = try await channel.call(event: "list_sessions")
        XCTAssertEqual((response["sessions"] as? [[String: Any]])?.first?["id"] as? String, "s1")
        await channel.disconnect()
    }

    func testUnansweredCallTimesOut() async throws {
        let channel = PhoenixChannel(callTimeout: .milliseconds(300))
        try await channel.connect(serverURL: stub.url, credential: "", topic: "lobby")
        do {
            _ = try await within(.seconds(3)) { try await channel.call(event: "never_answered") }
            XCTFail("call should time out")
        } catch {
            guard case ChannelError.timeout = error else { return XCTFail("expected timeout, got \(error)") }
        }
        await channel.disconnect()
    }

    // --- heartbeat ---

    func testUnansweredHeartbeatEndsTheChannel() async throws {
        stub.answerHeartbeats = false
        let channel = PhoenixChannel(heartbeatInterval: .milliseconds(200), heartbeatTimeout: .milliseconds(200))
        try await channel.connect(serverURL: stub.url, credential: "", topic: "lobby")

        let ended = Box(false)
        Task {
            for await _ in channel.pushes {}
            ended.update { $0 = true }
        }
        let noticed = await stub.eventually { ended.get() }
        XCTAssertTrue(noticed, "a silent server must be noticed: pushes finishes")
        let closed = await stub.eventually { self.stub.closedCount == 1 }
        XCTAssertTrue(closed, "and the socket is closed")
        let isConnected = await channel.isConnected
        XCTAssertFalse(isConnected)
    }

    func testInboundTrafficKeepsTheChannelOpenWhileHeartbeatRepliesAreSlow() async throws {
        // A session replay queues the heartbeat reply behind every replayed frame; frames arriving
        // prove the socket is alive. Once they stop, silence is still noticed.
        stub.answerHeartbeats = false
        let channel = PhoenixChannel(heartbeatInterval: .milliseconds(200), heartbeatTimeout: .milliseconds(200))
        try await channel.connect(serverURL: stub.url, credential: "", topic: "lobby")
        stub.startPushing(every: .milliseconds(40))
        let beat = await stub.eventually(.seconds(3)) { self.stub.heartbeatsSeen >= 4 }
        XCTAssertTrue(beat, "heartbeats should be flowing")
        let isConnected = await channel.isConnected
        XCTAssertTrue(isConnected)
        XCTAssertEqual(stub.closedCount, 0)

        stub.stopPushing()
        let closed = await stub.eventually(.seconds(3)) { self.stub.closedCount == 1 }
        XCTAssertTrue(closed, "silence after the traffic stops is a dead socket")
    }

    func testAnsweredHeartbeatsKeepTheChannelOpen() async throws {
        let channel = PhoenixChannel(heartbeatInterval: .milliseconds(150), heartbeatTimeout: .milliseconds(150))
        try await channel.connect(serverURL: stub.url, credential: "", topic: "lobby")
        let beat = await stub.eventually { self.stub.heartbeatsSeen >= 4 }
        XCTAssertTrue(beat, "heartbeats should be flowing")
        let isConnected = await channel.isConnected
        XCTAssertTrue(isConnected)
        XCTAssertEqual(stub.closedCount, 0)
        await channel.disconnect()
    }

    // --- one-shot lobby calls ---

    func testARefusedCallStillClosesTheLobbySocket() async throws {
        stub.refuse = ["rename_session"]
        let client = NascClient(endpoint: NascEndpoint(serverURL: stub.url))
        do {
            try await within(.seconds(3)) { try await client.renameSession(id: "s1", title: "x") }
            XCTFail("rename should be refused")
        } catch {
            guard case ChannelError.callFailed = error else { return XCTFail("expected callFailed, got \(error)") }
        }
        let closed = await stub.eventually { self.stub.closedCount == 1 }
        XCTAssertTrue(closed, "a failed call must not leave its socket open")
    }

    // --- a live feed survives a drop ---

    func testLobbyFeedComesBackAfterTheServerDrops() async throws {
        stub.replies = ["list_sessions": ["sessions": [["id": "s1", "slug": "one"]]]]
        let client = NascClient(endpoint: NascEndpoint(serverURL: stub.url))
        let stub = self.stub!
        let updates = try await within(.seconds(5)) { () -> [String] in
            var updates: [String] = []
            for await update in client.lobbyUpdates() {
                switch update {
                case .value(let list): updates.append("value:\(list.map(\.id).joined(separator: ","))")
                case .lost(let reason): updates.append("lost:\(reason)")
                }
                if updates.count == 1 { stub.dropAll() }
                if updates.count == 3 { break }
            }
            return updates
        }
        XCTAssertEqual(updates, ["value:s1", "lost:Disconnected", "value:s1"])
    }
}
