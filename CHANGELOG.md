# Changelog

## v0.1.0 — 2026-06-28

First Swift client.

- Phoenix-channels-over-WebSocket transport (`PhoenixChannel`, `PhoenixFrame`),
  harvested from RelayKit, adapted to nasc's `/client` socket.
- `NascClient`: createSession, listSessions, live `lobbyUpdates`, attach (event
  stream), prompt, decide, interrupt, renameSession, deleteSession, registerDevice.
- `NascEvent` / `SessionSummary` models.
- `nasckit-smoke` executable for live verification on macOS (no device needed).
