# NascKit

Swift client library for [nasc](https://github.com/mnotony/nasc) (iOS + macOS). Powers
[nasc-ios](https://github.com/mnotony/nasc-ios).

```swift
let client = NascClient(endpoint: NascEndpoint(serverURL: "ws://host:4100"))
let (id, _) = try await client.createSession()
let events = try await client.attach(sessionID: id)
try await client.prompt("hello")
for await event in events { /* tool_call / tool_result / assistant_msg / done */ }
```

`NascClient`: `createSession` · `listSessions` / `lobbyUpdates` (live) · `attach`
(event stream) · `prompt` · `decide` · `interrupt` · `renameSession` · `deleteSession`
· `registerDevice`. Transport: Phoenix channels over `URLSessionWebSocketTask`
(`PhoenixChannel`/`PhoenixFrame`, harvested from RelayKit, adapted to nasc's `/client`).

```sh
swift build
swift run nasckit-smoke ws://127.0.0.1:4100 "hello"   # live smoke against nasc (macOS)
```

## The stack

[nasc](https://github.com/mnotony/nasc) · [ogma](https://github.com/mnotony/ogma) ·
[croí](https://github.com/mnotony/croi) · [nasc-cli](https://github.com/mnotony/nasc-cli) ·
**NascKit** (this) · [nasc-ios](https://github.com/mnotony/nasc-ios)
