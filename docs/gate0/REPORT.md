# Gate 0 — Feasibility Spike Report

Plan: `docs/plans/2026-07-09-firmament-plan.md` §8. Status as of 2026-07-09 21:10 EDT.

## Spike 1 — Programmatic `codex app-server` under subscription auth: **PASS (protocol)**

`spikes/appserver_spike.py` drives `codex app-server` headlessly over stdio
JSON-RPC (no TTY, no user in the loop), under ChatGPT-subscription auth:

- `initialize` handshake succeeds; server self-reports codexHome and platform.
- `thread/start` with `ephemeral: true` and `sandbox: "read-only"` returns a
  thread id.
- `turn/start` accepts per-turn `model` (`gpt-5.6-terra`), `effort`, `input`,
  and — critically — a native `outputSchema` field: strict-JSON structured
  output is a first-class protocol feature, not prompt discipline.
- Turns run async: the response returns `status: inProgress`; completion
  arrives as `turn/completed` / `turn/failed` notifications with structured
  errors (`codexErrorInfo`), and rate limits stream as
  `account/rateLimits/updated`.
- Full protocol JSON Schemas are generatable via
  `codex app-server generate-json-schema` (v2 surface includes thread
  lifecycle, fs, approvals, account/auth-token refresh) — bindings can be
  generated, not hand-written, per the plan.

**Live finding — provider outage is real, and the protocol handles it well:**
the spike's turn failed with `usageLimitExceeded` (the day's heavy codex use
exhausted the subscription window; reset ~10:39 PM). The failure was
structured, immediate, and machine-readable — exactly what the plan's
runtime posture (§11: durable job queue absorbs outages, entries stay
browsable raw, degraded health) needs. This hardens, not weakens, the
subscription-compute decision: the failure mode is a first-class protocol
event, not a hang.

### Update — 2026-07-09 ~23:00, first live run of the production client

`FirmamentCore`'s own `CodexAppServerProvider` (not the Python spike) ran
against the real server from `firmament-service`: initialize handshake,
`thread/start` (whose live response nests the id as `thread.id` — the client
now accepts both shapes), `turn/start`, and turn-failure notifications all
validated on the wire. The observed failure was `usageLimitExceeded`
(quota contention with the concurrent review run), which the stack handled
exactly as designed: structured parse → `ReasoningError.usageLimitExceeded`
→ job parked with attempts unchanged. **Still pending**: the success path
(`item/completed` agentMessage shape) — scheduled for the next quota window;
until then a shape mismatch degrades to timeout→park, never terminal.

## Spike 2 — Extraction quality at workhorse tier: **first-sample PASS**

Ran earlier on 2026-07-09 via `codex exec` (same backend, same auth):
GPT-5.6 Terra @ xhigh processed a real 8-minute planning voice-note
transcript with the production schema and returned a faithful title,
description, facet, 7 decisions, 5 open loops, and a grounded,
person-directed deepening question with verbatim evidence. Closes only after
the routine/sparse/multi-speaker/adversarial + abstention battery (plan §8).

## Spike 3 — Granola: **path decided, key pending**

Operator confirmed Flatiron workspace is on a Business plan → cursor-polling
API connector. Key minting is an operator dashboard action (Settings → API);
connector development proceeds against documented API shapes with fixtures.
Fallback proven: the account's hosted OAuth MCP authenticates.

## Spikes 4–6 — pending

- **Agent-session capture** (Claude Code session-close hook; codex thread
  export): to be closed during Gate 1 connector work.
- **`prepare_session` auto-call rate**: requires the bridge to exist (Gate 2).
- **Local transcription quality** (SpeechAnalyzer vs whisper.cpp): to be
  closed when Self-facet voice capture lands.

## Consequence for the build

Architecture proceeds on the app-server provider design. The core's
`ReasoningProvider` gets: async turn tracking, structured failure taxonomy
(including `usageLimitExceeded` → durable job retry after reset), and
generated protocol types.
