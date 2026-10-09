# Changelog

## Unreleased

## v0.9.0 — 2026-10-08

- **`CredentialStore`** — per-server device credentials in the Keychain, shared by nasc-ios and
  nasc-mac (each had, or was about to have, its own copy). Every Keychain failure throws: a read the
  Keychain refused (a denied prompt, a locked keychain) is not "no credential" and must never be
  saved over as one. `save(_:server:replacing:)` stores (update, or add) and only then drops the
  credential under a server's old URL, so a failure never loses both; empty removes.
- **No credential in an error** — an unparseable socket URL threw `invalidURL` with the full URL,
  `&credential=<secret>` included, and the apps show that reason on screen. It now names the server
  URL only.
- **Required vs refused** — an upgrade refused with 401/403 says "credential required" when none
  was sent and "credential refused" when one was.

## v0.8.0 — 2026-10-08

Live lists that come back. Pairs with nasc-ios v0.9.0 and nasc-mac v0.2.0. **Breaking:** the live
feeds' signatures changed (below).

- **Self-healing feeds** — `lobbyUpdates()`, `fleetUpdates()`, `agentUpdates()` are now
  `nonisolated`, non-throwing, and return `AsyncStream<LiveUpdate<T>>`: `.value(snapshot)` while
  connected, `.lost(reason)` when the socket drops or can't be made, then they reconnect on their own
  (backoff 1, 2, 4, 8, 16, 30 s; reset after a connection that lasted 30 s). Before, each feed ended
  for good on the first drop. `fleetUpdates` / `agentUpdates` also end their connection on
  `phx_close` / `phx_error` now. `NascClient.backoff` is public for clients that retry on their own.
- **Connect has a deadline** — a join unanswered in 15 s throws `timeout`, counted from the start, so
  a send that can't go out times out too. Offline, a connect fails at once (`waitsForConnectivity`
  is off; one shared `URLSession` replaces one per connection, which were never invalidated). An
  upgrade refused with HTTP 401/403 throws `joinFailed("credential refused (HTTP 403)")`.
- **Nothing leaks** — a failed connect, and every one-shot lobby call whose call fails
  (`createSession`, `listProjects`, `listSessions`, `deleteSessions`, renames/deletes/agent edits,
  `registerDevice`), closes its socket. Cancelling a join or call fails it at once.
- **Dead sockets are noticed** — a heartbeat with no reply in 10 s, while nothing else arrived,
  drops the connection (any inbound frame counts as alive: a session replay delays the reply).
- `PhoenixChannel(joinTimeout:callTimeout:heartbeatInterval:heartbeatTimeout:)`.

## v0.7.0 — 2026-10-08

Bulk delete. Pairs with nasc-ios v0.8.0 (select several sessions, delete once).

- **`NascClient.deleteSessions(ids:)`** — delete several sessions over one lobby connection and get
  back the ids that weren't deleted. A server refusal fails just that id; a dropped socket fails that
  id and the rest untried, instead of each waiting out the 30 s call timeout. A failed id that a fresh
  `list_sessions` no longer shows counts as deleted (nasc refuses an already-archived session the
  same way it refuses a real failure). Throws only if the lobby can't be joined.
- **`SessionSummary.isLive`** — `running` or `awaiting_input`: a delete (archive) won't stop it.

## v0.6.0 — 2026-09-29

Read a session as a conversation. Pairs with ogma's `tool_call` narration and nasc-ios v0.7.0.

- **`NascEvent.narration`** — the prose the agent wrote before a tool call (`metadata.narration` on
  the turn's first `tool_call`), which until now only streamed as tokens and was lost when the call
  landed.
- **`Conversation.items`** — a pure projection of a session's events into `ConversationItem`s: the
  user's messages, the agent's (final answers and narration), `system` notices, and everything
  between folded into a `Steps` group with its tool count and last tool. Each user entry carries its
  `Delivery`: a client-local `interrupt` echo is `.queued` until the agent logs it as a `user_msg`, and
  an `unsent` echo (sending failed) is `.unsent`.
- **`Conversation.merge`** — fold an incoming event into what a client holds without clearing it: a
  reconnect's full replay drops what is already on screen, slots in what was missed by sequence
  (including the `user_msg`s nasc never broadcasts live), and lets a logged `user_msg` take its echo's
  place (even an `unsent` one whose reply was lost, not the prompt) — so local echoes survive a
  reconnect where they were typed.
- **Streams end when the channel does** — `attach` and `lobbyUpdates` finish on `phx_close` or
  `phx_error` (`InFrame.endsChannel`; `PhoenixChannel` now forwards `phx_close`) instead of leaving a
  client that reads as attached to a channel that will never push again.

## v0.5.1 — 2026-09-04

- **`/tts` credential** (#11) — `NascClient.synthesize` sends the endpoint's device credential as
  `Authorization: Bearer <credential>` on the `/tts` POST (omitted when empty), so voice mode keeps
  working once nasc requires a credential on `/tts`.

## v0.5.0 — 2026-09-03

Authenticate the `/client` socket with a per-device credential.

- **Device credential** (#9) — `NascEndpoint` now carries a per-device `credential` (issued by nasc,
  `mix nasc.credential issue device …`) in place of the ignored placeholder token. `PhoenixChannel`
  appends `?credential=` only when it's set, so an empty value takes nasc's open (dual-accept) path
  unchanged during migration.
- **BREAKING** — `NascEndpoint(token:)` is renamed to `NascEndpoint(credential:)` (and the
  `token` property to `credential`). Update call sites to pass `credential:`.

## v0.4.0 — 2026-09-02

Model the input/approval contract and edit diffs, so the app can render them.

- **`Approval`** (#5) — parses `input_requested` into a typed value (`tool` / `reauth` / a pre-contract
  fallback) with tool, summary, reason, severity, and an `expires_at`. `NascEvent` now carries `approval`
  (on `input_requested`) and `outcome` (on the new `input_provided`).
- **`EditDiff`** (#6) — parses an edit tool's `tool_result` (a `path (+N -M)` summary + a `+`/`-` diff)
  into a summary, counts, and classified lines, for a coloured transcript diff.
- **`SessionSummary.runState`** (#7) — carries the live run-state (`running` / `awaiting_input` /
  `interrupted` / `idle`) from `list_sessions`, so the session list can differentiate by run-state.
- Adds a `NascKitTests` target (12 tests).

## v0.3.0 — 2026-07-24

- **Agent roots + autonomy API** — new `Agent` model (`id` / `online` / `capabilities` / `roots` /
  `autonomous`) + `NascClient` methods: `listAgents`, `agentUpdates` (live, re-yields on
  `agents_changed` / `fleet_changed`), `setAgentAutonomy`, `addAgentRoot`, `removeAgentRoot`.
  `createSession(autonomy:)` turns a single task loose. Backs the nasc-ios Agents screen.

## v0.2.0 — 2026-07-03

Projects: the picker source + project-scoped session creation.

- **Projects** — `NascClient.listProjects()` returns the registered projects (the picker source),
  and `createSession(project:)` scopes a new session to one so nasc routes it to an agent that can
  reach it. Adds the `Project` model (`name`, `capability`, `title`).

## v0.1.0 — 2026-06-28

First Swift client.

- Phoenix-channels-over-WebSocket transport (`PhoenixChannel`, `PhoenixFrame`),
  harvested from RelayKit, adapted to nasc's `/client` socket.
- `NascClient`: createSession, listSessions, live `lobbyUpdates`, attach (event
  stream), prompt, decide, interrupt, renameSession, deleteSession, registerDevice.
- `NascEvent` / `SessionSummary` models.
- `nasckit-smoke` executable for live verification on macOS (no device needed).
