# Gate 0 — Feasibility Spike Report

Plan: `docs/plans/2026-07-09-firmament-plan.md` §8. Status as of 2026-07-10.

## Spike 1 — Programmatic `codex app-server` under subscription auth: **PASS (production success path)**

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
→ job parked with attempts unchanged. At that point, the success path
(`item/completed` agent-message shape) remained pending.

### Closeout — 2026-07-10, production success

The first disposable certification run exposed a live contract defect before
inference: the structured-output API rejected the nested `question` schema because
not every declared property was listed in `required`. The run stopped after that
single failed attempt. The schema was corrected, nullable fields remained nullable,
and a focused regression now enforces strict-schema completeness.

A fresh synthetic `FIRMAMENT_HOME` was then created with mode `0700`; the service's
logged vault path was checked before the fixture was created, and the production
Application Support vault remained unchanged. The successful lifecycle proved:

- a second writable service was rejected while MCP health on the first remained
  healthy;
- a non-local synthetic entry reached `done` with attempts `0` and no error;
- a `gpt-5.6-terra` / `extract-v1` succeeded analysis, linked projection, and FTS row
  persisted;
- the model returned `abstain: false`, and exactly one matching open question was
  stored;
- after the provider child ran, terminating the exact service and restarting against
  the same disposable home reacquired the persistent lock and replaced the stale
  socket; the provider root was still alive at the release boundary, proving the lock
  descriptor was close-on-exec.

The disposable home and its exact provider process tree were removed after proof.
This completes Spike 1's production success path only. Spike 2's extraction battery
and Spikes 3–6 remain open.

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

## Post-merge stabilization — 2026-07-10

Merged [PR #2](https://github.com/draphael89/Firmament/pull/2) is now the active
SwiftPM vault/guardian product. PR #1's incompatible FirmamentKit, Xcode, macOS/iOS,
scripts, and superseded planning artifacts were removed from the current tree while
remaining available through Git history at `f4ffdef`.

- CI builds all three SwiftPM executables and runs the complete package suite from
  `app/`; `app/Package.resolved` is committed and checked for drift.
- Writable vaults acquire a persistent mode-`0600`, close-on-exec `service.lock`
  before storage opens; read-only vaults remain concurrent.
- Socket startup distinguishes absent stale paths from unlink failures and releases
  descriptors on every failed initialization path.
- Successful extraction reprocessing atomically retires the prior open question,
  including on abstention; malformed non-abstaining output preserves the old question.
- All three executables build, and `swift test --package-path app` passes **58 tests
  across 9 suites**. `actionlint`, capture-hook `bash -n`, `git diff --check`,
  final-tree reference checks, and the site-diff check pass. `site/**` remains
  byte-identical to merge `ecbbf1ff`.

This stabilization closes neither the Spike 2 extraction battery nor the remaining
Gate 0 spikes, and it does not install dogfood configuration, hooks, identity data,
connectors, or a LaunchAgent.
