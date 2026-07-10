# Firmament

A Mac-first personal memory vault whose payoff is better work with Claude and
Codex. Three facets by provenance — **Self** (voice/text notes), **Others**
(Granola meetings), **Agents** (Claude/Codex sessions) — processed by GPT-5.6
through `codex app-server` under the operator's ChatGPT subscription, and
served back to agents through the **Agent Bridge** (MCP).

Plan of record: [`../docs/plans/2026-07-09-firmament-plan.md`](../docs/plans/2026-07-09-firmament-plan.md).

## Pieces

| binary | role |
|---|---|
| `firmament-service` | Sole vault owner: SQLite (GRDB/WAL) + content-addressed raw store, durable job queue, extraction pipeline, inbox pollers, Granola sync, bridge socket |
| `firmament-mcp` | Thin MCP stdio adapter → service socket. Tools: `prepare_session`, `ask_glia`, `explain_session`, `record_outcome`, `health` |
| `firmament-app` | Vault browser: facets, search, questions, capture (⌘N), Trash + Delete Now |

Vault home: `~/Library/Application Support/Firmament` (override:
`FIRMAMENT_HOME`). Inside it: `vault.sqlite`, `objects/`, `inbox/`,
`agent-inbox/{claude_code,codex}/`, `identity.md` (operator-curated, served
under the `curated` trust label), persistent `service.lock`, and optional
`granola.key`.

## Run

```sh
cd app
swift build
.build/debug/firmament-service &   # must be running for capture/bridge
.build/debug/firmament-app
```

## Hook up the agents

**Claude Code MCP** (`~/.claude.json` or project `.mcp.json`):

```json
{
  "mcpServers": {
    "firmament": { "command": "/path/to/.build/debug/firmament-mcp" }
  }
}
```

**Claude Code SessionEnd hook** (`~/.claude/settings.json`):

```json
{
  "hooks": {
    "SessionEnd": [{ "hooks": [{ "type": "command",
      "command": "/path/to/integrations/claude-code/firmament-capture.sh" }] }]
  }
}
```

**Codex** (`~/.codex/config.toml`):

```toml
[mcp_servers.firmament]
command = "/path/to/.build/debug/firmament-mcp"
env = { FIRMAMENT_CLIENT = "codex" }
```

**Granola** (Business plan): mint an API key (Settings → API), write it to
`~/Library/Application Support/Firmament/granola.key`. The service syncs
every 5 minutes, revision-aware.

**iPhone capture**: point a Shortcut (share sheet / Action button) at the
iCloud Drive folder you map to `inbox/` — files land as `.partial` then
rename; text imports immediately, audio awaits the transcription stage.

## Invariants worth knowing

- **One writable owner per vault**: a nonblocking advisory lock makes a second
  writer fail fast; read-only WAL connections remain concurrent.
- **Raw truth is immutable per revision**; all derived data is reprocessable.
- **Delete Now is provable**: one transaction purges rows, jobs, and FTS;
  content objects are unlinked when unreferenced; an open-time sweep reclaims
  crash orphans. (Unlink, not secure overwrite — APFS makes no such promise.)
- **`local_only` is structural**: enforced in the storage layer at query
  construction; local-only entries never reach a provider, a packet, or
  search results for egress consumers.
- **Packets quote, never instruct**: everything imported enters agent
  contexts inside fenced evidence blocks with citations and trust labels
  (`curated` / `supported`), with honest unknowns and a dropped-content
  manifest (`explain_session`).
- **Provider outages degrade gracefully**: usage-limit and auth failures
  park jobs without burning retry attempts; entries stay browsable raw.

## Tests

```sh
cd app && swift test   # 56 tests: storage, purge, jobs, pipeline, bridge, connectors
```
