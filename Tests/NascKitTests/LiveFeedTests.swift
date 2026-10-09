import Foundation
import XCTest

@testable import NascKit

final class LiveFeedTests: XCTestCase {
    /// Collect the first `n` updates, then stop listening.
    private func first<V: Sendable>(_ n: Int, of stream: AsyncStream<LiveUpdate<V>>) async -> [LiveUpdate<V>] {
        var out: [LiveUpdate<V>] = []
        for await update in stream {
            out.append(update)
            if out.count == n { break }
        }
        return out
    }

    /// A feed that yields `values` and then stays open, or finishes if `finish` is set.
    private func feed(_ values: [Int], finish: Bool = false, onEnd: (@Sendable () -> Void)? = nil) -> AsyncStream<Int> {
        AsyncStream { c in
            for v in values { c.yield(v) }
            if let onEnd { c.onTermination = { _ in onEnd() } }
            if finish { c.finish() }
        }
    }

    private let noSleep: @Sendable (Duration) async -> Void = { _ in }

    /// A feed that yields `value`, then, when next read, lets `elapsed` pass on `clock` and ends —
    /// time passes while the connection is up, not while it opens.
    private func upFor(_ elapsed: Duration, yielding value: Int, clock: Box<Duration>) -> AsyncStream<Int> {
        let reads = Box(0)
        return AsyncStream(unfolding: {
            reads.update { $0 += 1 }
            if reads.get() == 1 { return value }
            clock.update { $0 += elapsed }
            return nil
        })
    }

    // --- values and drops ---

    func testValuesPassThrough() async {
        let stream = NascClient.resilient(open: { self.feed([1, 2]) }, sleep: noSleep)
        let got = await first(2, of: stream)
        XCTAssertEqual(got, [.value(1), .value(2)])
    }

    func testFeedEndingYieldsLostThenReopens() async {
        let opens = Box(0)
        let stream = NascClient.resilient(open: {
            opens.update { $0 += 1 }
            return opens.get() == 1 ? self.feed([1], finish: true) : self.feed([2])
        }, sleep: noSleep)
        let got = await first(3, of: stream)
        XCTAssertEqual(got, [.value(1), .lost("Disconnected"), .value(2)])
    }

    func testOpenFailureYieldsLostWithItsReasonThenRetries() async {
        let opens = Box(0)
        let stream = NascClient.resilient(open: {
            opens.update { $0 += 1 }
            if opens.get() == 1 { throw ChannelError.timeout }
            return self.feed([5])
        }, sleep: noSleep)
        let got = await first(2, of: stream)
        XCTAssertEqual(got, [.lost("Request timed out"), .value(5)])
    }

    // --- backoff ---

    func testBackoffDoublesFromOneSecondAndCapsAtThirty() async {
        let sleeps = Box<[Duration]>([])
        let stream = NascClient.resilient(
            open: { () async throws -> AsyncStream<Int> in throw ChannelError.disconnected },
            sleep: { d in sleeps.update { $0.append(d) } }
        )
        _ = await first(8, of: stream)
        XCTAssertEqual(Array(sleeps.get().prefix(7)), [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
    }

    func testBackoffResetsAfterAConnectionThatLastedThirtySeconds() async {
        let clock = Box<Duration>(.zero)
        let base = ContinuousClock.now
        let sleeps = Box<[Duration]>([])
        let opens = Box(0)
        let stream = NascClient.resilient(
            open: {
                opens.update { $0 += 1 }
                switch opens.get() {
                case 1, 2: throw ChannelError.disconnected  // backoff 1 s, 2 s
                case 3:
                    // Up for 30 s, then dropped.
                    return self.upFor(.seconds(30), yielding: 3, clock: clock)
                default: throw ChannelError.disconnected
                }
            },
            sleep: { d in sleeps.update { $0.append(d) } },
            now: { base.advanced(by: clock.get()) }
        )
        _ = await first(5, of: stream)  // lost, lost, value(3), lost, lost
        XCTAssertEqual(Array(sleeps.get().prefix(4)), [1, 2, 1, 2].map { Duration.seconds($0) })
    }

    func testBackoffKeepsGrowingAfterAShortConnection() async {
        let clock = Box<Duration>(.zero)
        let base = ContinuousClock.now
        let sleeps = Box<[Duration]>([])
        let opens = Box(0)
        let stream = NascClient.resilient(
            open: {
                opens.update { $0 += 1 }
                switch opens.get() {
                case 1, 2: throw ChannelError.disconnected  // backoff 1 s, 2 s
                case 3:
                    // Accepted and answered, then dropped 5 s later: not a recovery.
                    return self.upFor(.seconds(5), yielding: 3, clock: clock)
                default: throw ChannelError.disconnected
                }
            },
            sleep: { d in sleeps.update { $0.append(d) } },
            now: { base.advanced(by: clock.get()) }
        )
        _ = await first(5, of: stream)
        XCTAssertEqual(Array(sleeps.get().prefix(4)), [1, 2, 4, 8].map { Duration.seconds($0) })
    }

    // --- cancellation ---

    func testAFeedThatOpensAfterCancellationIsStillEnded() async throws {
        // A feed that finishes opening after the consumer has gone must still be ended — its socket
        // closed — even though it holds its own continuation, as a lobby feed does.
        let ended = expectation(description: "the late feed is terminated")
        let stream = NascClient.resilient(open: {
            try? await Task.sleep(for: .milliseconds(200))  // still connecting when cancelled
            return AsyncStream<Int> { c in
                let holder = Task { while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }; _ = c }
                c.onTermination = { _ in holder.cancel(); ended.fulfill() }
            }
        }, sleep: noSleep)
        let consumer = Task { await self.first(99, of: stream) }
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        await fulfillment(of: [ended], timeout: 2)
    }

    func testCancellingTheConsumerEndsTheOpenFeedAndStopsReopening() async throws {
        let opens = Box(0)
        let ended = expectation(description: "the open feed is terminated")
        let stream = NascClient.resilient(open: {
            opens.update { $0 += 1 }
            return self.feed([1], onEnd: { ended.fulfill() })
        }, sleep: noSleep)

        let consumer = Task { await self.first(99, of: stream) }
        try await Task.sleep(for: .milliseconds(100))
        consumer.cancel()
        await fulfillment(of: [ended], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(opens.get(), 1)
    }
}
