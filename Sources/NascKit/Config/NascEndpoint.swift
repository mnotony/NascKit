import Foundation

/// Where to reach nasc, and the per-device credential to authenticate with. `serverURL` is a
/// `ws://` or `wss://` URL. `credential` is issued by nasc (`mix nasc.credential issue device …`)
/// and presented on the `/client` socket; empty means an unauthenticated (dual-accept) connection.
public struct NascEndpoint: Sendable {
    public let serverURL: String
    public let credential: String

    public init(serverURL: String = NascEndpoint.defaultServerURL, credential: String = "") {
        self.serverURL = serverURL
        self.credential = credential
    }

    public static let defaultServerURL = "ws://127.0.0.1:4100"
    public static let lobbyTopic = "lobby"

    public var httpBase: String { Self.httpBase(from: serverURL) }

    public static func httpBase(from serverURL: String) -> String {
        if serverURL.hasPrefix("wss://") { return "https://" + String(serverURL.dropFirst(6)) }
        if serverURL.hasPrefix("ws://") { return "http://" + String(serverURL.dropFirst(5)) }
        return serverURL
    }
}
