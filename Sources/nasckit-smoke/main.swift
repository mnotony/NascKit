import Foundation
import NascKit

// Live smoke: drives a real session against nasc on this Mac (no iOS device needed).
//   swift run nasckit-smoke [ws://host:port] [prompt]

let args = CommandLine.arguments
let server = args.count > 1 ? args[1] : "ws://127.0.0.1:4100"
let prompt = args.count > 2 ? args[2] : "Reply with exactly: nasckit-ok"

let client = NascClient(endpoint: NascEndpoint(serverURL: server))

do {
    let (id, slug) = try await client.createSession()
    print("session \(slug) (\(id))\n")

    let events = try await client.attach(sessionID: id)
    print("you: \(prompt)\n")
    try await client.prompt(prompt)

    for await event in events {
        switch event.kind {
        case "token":
            FileHandle.standardOutput.write(Data((event.content ?? "").utf8))
        case "assistant_msg":
            print(event.content ?? "")
        case "tool_call":
            print("  → \(event.content ?? "")")
        case "tool_result":
            print("  ← \(String((event.content ?? "").prefix(120)))")
        case "input_requested":
            print("  ⚠ approval requested (\(event.content ?? "")) — auto-approving")
            try await client.decide(requestID: event.requestID ?? "", approve: true)
        case "done":
            print("\n[done]")
            await client.disconnect()
            exit(0)
        default:
            break
        }
    }
} catch {
    print("error: \(error)")
    exit(1)
}
