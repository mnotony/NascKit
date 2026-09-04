# Changelog

## Unreleased

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
