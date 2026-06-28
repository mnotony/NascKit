import Foundation

/// Where to reach nasc, and the token to authenticate with. `serverURL` is a
/// `ws://` or `wss://` URL; nasc's `/client` socket currently accepts any token.
public struct NascEndpoint: Sendable {
    public let serverURL: String
    public let token: String

    public init(serverURL: String = NascEndpoint.defaultServerURL, token: String = "") {
        self.serverURL = serverURL
        self.token = token
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
