import Foundation

/// A Phoenix channel connection. Implemented by `PhoenixChannel` (real) and mocks.
public protocol ChannelProtocol: Actor {
    nonisolated var pushes: AsyncStream<InFrame> { get }
    var isConnected: Bool { get }
    func connect(serverURL: String, token: String, topic: String) async throws
    func call(event: String, payload: [String: Any]) async throws -> [String: Any]
    func cast(event: String, payload: [String: Any]) async throws
    func disconnect()
}
