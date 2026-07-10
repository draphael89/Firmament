# Firmament

**Firmament is the vault. Glia is the guardian inside it.**

Firmament is a Mac-first personal memory vault for one operator. It captures Self,
Others, and Agents provenance; keeps raw revisions locally in SQLite plus a
content-addressed store; derives titles, summaries, entities, and at most one grounded
question through `codex app-server`; and serves cited context to Claude and Codex through
the Agent Bridge.

The plan of record is
[`docs/plans/2026-07-09-firmament-plan.md`](docs/plans/2026-07-09-firmament-plan.md).
The earlier append-only ledger architecture is retained in Git history only.

## Repository layout

```text
app/                  Swift package: core, service, MCP adapter, Mac app, tests
docs/plans/           Product and architecture plan of record
docs/gate0/           Feasibility evidence and deferred verification status
integrations/         Agent capture integrations
spikes/               Disposable feasibility probes
site/                 Existing static landing page; product copy is not yet retargeted
```

## Build and test

```sh
cd app
swift build
swift test
```

The build produces `firmament-service`, `firmament-mcp`, and `firmament-app`. See
[`app/README.md`](app/README.md) for vault paths, runtime roles, and agent wiring.

## Current product boundaries

- `firmament-service` is the sole writable owner of a vault; the Mac app reads WAL and
  sends mutations over the local socket.
- `local_only` and Trash are structural egress filters. Delete Now physically purges
  rows, jobs, index entries, and unreferenced content objects.
- Intelligence uses the operator's ChatGPT subscription through `codex app-server`.
  Metered API billing is not enabled.
- The native iOS/CloudKit/append-only-ledger implementation from PR #1 is superseded.
  Voice capture and local transcription return in later gates under the current plan.

## Landing page

`site/` is the original static “Ledger Made Law” landing page. It remains deployable and
byte-for-byte unchanged during the core stabilization work, but its story no longer
describes the active product architecture.

```sh
python3 -m http.server 4000 --directory site
```

Production currently lives at <https://firmament-tau.vercel.app>.
