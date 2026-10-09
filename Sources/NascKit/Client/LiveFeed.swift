import Foundation

/// One update from a live feed that outlives dropped sockets.
public enum LiveUpdate<Value: Sendable>: Sendable {
    /// A fresh snapshot: the feed is connected.
    case value(Value)
    /// The connection dropped or couldn't be made (the reason); the feed is retrying.
    case lost(String)
}

extension LiveUpdate: Equatable where Value: Equatable {}

extension NascClient {
    /// A connection that stays up this long has recovered: the next drop backs off from the start.
    static let recovered: Duration = .seconds(30)

    /// Seconds to wait before reconnect attempt `attempt`: 1, 2, 4, 8, 16, then 30.
    public static func backoff(_ attempt: Int) -> Duration {
        .seconds(min(30, 1 << min(attempt, 5)))
    }

    /// Keep a live feed going across dropped sockets: forward each value of the feed `open` returns;
    /// when it ends, or `open` throws, say so (`.lost`), back off, and open it again — until the
    /// returned stream is cancelled, which also ends the feed that is open.
    static func resilient<Value: Sendable>(
        open: @escaping @Sendable () async throws -> AsyncStream<Value>,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) -> AsyncStream<LiveUpdate<Value>> {
        AsyncStream { continuation in
            let task = Task {
                var attempt = 0
                while !Task.isCancelled {
                    let reason: String
                    do {
                        let feed = try await open()
                        let opened = now()
                        for await value in feed { continuation.yield(.value(value)) }
                        if now() - opened >= recovered { attempt = 0 }
                        reason = ChannelError.disconnected.localizedDescription
                    } catch {
                        reason = error.localizedDescription
                    }
                    guard !Task.isCancelled else { break }
                    continuation.yield(.lost(reason))
                    await sleep(backoff(attempt))
                    attempt += 1
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One lobby connection: fetch and yield, then fetch again on each of `events`. It ends with the
    /// connection (or the channel); if the first fetch fails it throws instead, since a connected
    /// socket with nothing to show is a failure to retry, not a blank screen.
    static func lobbyFeed<T: Sendable>(
        _ endpoint: NascEndpoint,
        refreshOn events: Set<String>,
        fetch: @escaping @Sendable (PhoenixChannel) async throws -> T
    ) async throws -> AsyncStream<T> {
        let lobby = PhoenixChannel()
        try await lobby.connect(serverURL: endpoint.serverURL, credential: endpoint.credential, topic: NascEndpoint.lobbyTopic)
        let first: T
        do {
            first = try await fetch(lobby)
        } catch {
            await lobby.disconnect()
            throw error
        }
        let pushes = lobby.pushes

        return AsyncStream { continuation in
            continuation.yield(first)
            let task = Task {
                for await frame in pushes {
                    if frame.endsChannel { break }
                    guard events.contains(frame.event) else { continue }
                    if let value = try? await fetch(lobby) { continuation.yield(value) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await lobby.disconnect() }
            }
        }
    }
}
