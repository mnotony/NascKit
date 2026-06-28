import Foundation

/// Outgoing frame: client → server. Phoenix v2 wire format:
/// `[join_ref, ref, topic, event, payload]`.
public struct OutFrame {
    public let joinRef: String?
    public let refID: String
    public let topic: String
    public let event: String
    public let payload: [String: Any]

    public init(joinRef: String?, refID: String, topic: String, event: String, payload: [String: Any]) {
        self.joinRef = joinRef
        self.refID = refID
        self.topic = topic
        self.event = event
        self.payload = payload
    }

    public func serialize() -> String {
        let joinRefValue: Any = joinRef.map { $0 as Any } ?? NSNull()
        let arr: [Any] = [joinRefValue, refID, topic, event, payload]
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }
}

/// Incoming frame: server → client.
public struct InFrame: @unchecked Sendable {
    public let refID: String?
    public let topic: String
    public let event: String
    public let payload: [String: Any]

    public init(refID: String?, topic: String, event: String, payload: [String: Any]) {
        self.refID = refID
        self.topic = topic
        self.event = event
        self.payload = payload
    }

    public static func parse(_ text: String) throws -> InFrame {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let arr = json as? [Any] else {
            throw FrameError.invalidJSON
        }
        guard arr.count == 5 else { throw FrameError.wrongLength(arr.count) }
        guard let topic = arr[2] as? String else { throw FrameError.missingField("topic") }
        guard let event = arr[3] as? String else { throw FrameError.missingField("event") }

        return InFrame(
            refID: arr[1] as? String,
            topic: topic,
            event: event,
            payload: arr[4] as? [String: Any] ?? [:]
        )
    }
}

public enum FrameError: Error, LocalizedError {
    case invalidJSON
    case wrongLength(Int)
    case missingField(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "Invalid JSON"
        case .wrongLength(let count): return "Expected 5-element array, got \(count)"
        case .missingField(let field): return "Missing \(field)"
        }
    }
}
