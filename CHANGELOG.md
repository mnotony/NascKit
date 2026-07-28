# Changelog

## Unreleased

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
