# Firmament — Prioritized Plan (2026-07-09)

**Firmament is the vault. Glia is the guardian inside it.**

A Mac-first, evidence-backed self-model whose primary payoff is better work with Claude
and Codex. Capture, browsing, and search are necessary substrate; the differentiator is
the Agent Bridge — an agent that knows who you are, negotiates on your behalf at the
start of every consequential AI session, and deepens its understanding of you with one
incisive question per entry.

This plan supersedes the old Firmament SPEC.md ("The Ledger Made Law") and builds on the
2026-07 Glia analysis verdict. It is written to be executed via the forge loop: each
gate below decomposes into design-complete specs implemented by GPT-5.6 and reviewed
cross-vendor.

---

## 1. Verified today (2026-07-09)

These are facts from this session, not assumptions:

- **Codex subscription compute is real.** `codex` CLI 0.144.0 installed, logged in via
  ChatGPT subscription (not API key). `codex app-server` exists (experimental) with a
  managed daemon, control socket, TypeScript binding generation, and JSON Schema
  protocol generation — exactly the embedding surface the core service needs.
- **Granola data is reachable.** The claude.ai Granola MCP connector is live on the
  operator's account (david@flatironcollective.com, "Flatiron" workspace) and can list
  meetings and pull transcripts today. The app still needs its own access path
  (personal API key or Granola's OAuth MCP consumed as a client) — Gate 0 item.
- **Glia repo is clean at `ab16808`**, matching the prior analysis (36/36 Mac tests as
  of that pass). The v17 psyche-injection replication is preregistered, not yet run.
- **Processing-quality spike ran live**: this very planning transcript was pushed
  through GPT-5.6 Terra at xhigh with the production extraction schema (title,
  description, facet, decisions, open loops, one grounded deepening question).
  Result and quality judgment: §9.

## 2. What changed since the prior verdict

The re-recorded transcript sharpens four things; the plan changes accordingly.

1. **Subscription-only compute is a hard requirement.** "As long as it's able to be run
   through a subscription, so I'm not paying a la carte." No metered-API fallback
   without explicit approval. All intelligence flows through subscription-authenticated
   `codex app-server` behind a `ReasoningProvider` seam (a future local model — the
   "holy guardian angel" — is a second provider behind the same seam).
2. **iOS is out of v1, deliberately.** Native iPhone capture points (Voice Memos,
   Notes, a Shortcut share action) feed a watched iCloud Drive inbox folder. No Swift
   iOS app until the Mac product earns one.
3. **Priority inversion: the Agent Bridge moves ahead of the deepening loop.** The
   transcript is explicit: capture/recall is "relatively easy"; improving agentic
   workflows is "most challenging but also most important." The old gate order
   (vault → deepening → bridge) buries the differentiator. New order: vault → bridge
   v0 → deepening → guardian experiment. The bridge v0 rides on a hand-curated
   identity document plus retrieval (both of which Glia already has); the deepening
   loop then upgrades the bridge's substrate from curated text to evidence-backed
   assertions. Two additional reasons: dogfooding the bridge generates the
   Agents-facet corpus the deepening loop needs, and the bridge is what makes this a
   daily tool rather than a diary. The spec critique added a real constraint: the
   five-label trust taxonomy needs Gate 3's assertion machinery, so bridge v0 makes
   claims only by direct excerpt citation (§5) — the reorder survives, with honest
   v0 semantics.
4. **The old Firmament constitution is formally superseded, not amended.** Keep its
   thesis (identity substrate; agent-legible; "the scarce input becomes personal
   context") and its best vocabulary (the Gate). Drop as v1 requirements: the
   append-only Ledger (immediate physical deletion and reprocessing are first-class
   here), on-device-by-default with egress-as-ceremony (Codex-server processing is the
   declared default), the Sanctum sensitivity-tier machinery, and the nightly-only
   Dream Cycle (process on ingest; a nightly consolidation pass can come later).

## 3. Product shape

Three facets, used as **provenance, not separate ontologies**:

| Facet | Origin | V1 source |
|---|---|---|
| **Self** | Solo voice/text | Mac capture (text + voice), drag-and-drop, watched iCloud inbox fed by iPhone Shortcut/Voice Memos/Notes export |
| **Others** | Multi-speaker | Granola Business API (cursor polling, revision-aware) |
| **Agents** | AI sessions | Claude Code session-close hook + Codex app-server thread capture + `record_outcome` tool |

An entry has one primary facet by origin, then secondary people/projects/themes. Never
duplicated across facets.

**Import durability conventions** (all sources): writers land files as `*.partial`
then atomically rename; the watcher additionally waits a quiescence window (iCloud
Drive syncs are not atomic); entries dedupe by content hash of the raw bytes (a
Shortcut delivery and a manual drag of the same file import once); malformed files
quarantine to a visible triage list, never fail silently. Granola sync is
revision-aware: remote edits create new revisions; remote deletions tombstone the
local entry ("source deleted" — operator decides retention).

Every entry gets: a name, a description, a classification — and **one question or an
explicit abstention**. Questions are ranked for expected information gain against the
whole vault, never generic, and abstention is a first-class outcome (forcing questions
onto routine content creates noise that erodes trust in the loop).

**Payoff hierarchy** (build-order tiebreaker when scope pressure hits):
1. Agent Bridge — steering Claude/Codex with who-you-are context and "ignited ambition"
2. Deepening loop — every input becomes a hook for the single most valuable question
3. Beautiful capture/browse/search — parsimonious, editorial, never a masonry grid

## 4. Architecture (ratified from prior verdict)

```
Sources (Self / Others / Agents)
      → Durable import inbox
      → GliaCoreService (background helper, SOLE SQLite writer, runs with app closed)
          ├─ GRDB + SQLite (WAL) + FTS5
          ├─ Content-addressed media files
          ├─ Durable job queue (transcribe → extract → reconcile → question → project)
          └─ ReasoningProvider → CodexProvider (app-server, subscription auth)
      ↔ Native Mac app (client)
      ↔ Thin MCP adapter (TypeScript, versioned local socket) ↔ Claude / Codex
```

- **Fresh repo (decided 2026-07-09, overriding the evolve-in-place recommendation)**:
  a new codebase — `FirmamentCore` Swift package + core-service helper + Mac app +
  thin MCP adapter. Glia pieces cross over selectively, as imported code or as
  reference: the theme, command palette, inspector anatomy, constellation renderer,
  injection preview/health language, the tested 40/60 packet policy, and the MCP
  instructions pattern. The first Gate 1 artifact is an import/reference matrix of
  exactly what crosses. The local-socket protocol is greenfield either way (Glia's
  MCP is bare stdio, version "0.1.0"): define it schema-first with generated
  bindings — the same move codex app-server makes.
- **Seed migration, not coexistence** (closes the critique's gbrain-orphan finding):
  Glia's live substrate today is an external `gbrain` CLI it shells out to, plus a
  hand-curated `psyche.md`. Neither stays a runtime dependency — the new core never
  shells out to gbrain. At Gate 1, `psyche.md` imports as the operator-ratified
  curated identity document (bridge v0's `curated` substrate), and the gbrain corpus
  imports through the standard inbox as Self-facet entries with migration provenance.
  gbrain is then retired from this stack.
- **Storage records** (from prior verdict): `source`, `entry`, `entry_revision`,
  `transcript_segment`, `analysis_run`, `entry_projection`, `profile_assertion`,
  `assertion_evidence`, `question`, `job`, `agent_session`. Raw truth is immutable per
  revision, with an explicit revision-ancestry chain; content addressing hashes the
  raw imported bytes; derived data is always reprocessable.
- **Deletion semantics** (pinned now — deletion killed the old ledger design, so it
  gets real definitions): Delete Now purges raw files, derived rows, FTS, embeddings,
  and cached packets transactionally, cancels the entry's pending jobs, and verifies
  postconditions. A `profile_assertion` that loses evidence to deletion downgrades:
  remaining evidence → `tentative`; none → retracted from Portrait and packets.
  Honesty clauses: packets already delivered to a live agent session cannot be clawed
  back (the audit records that this happened), and physical deletion means unlink +
  row purge, not secure overwrite — APFS makes no such promise.
- **Job queue semantics**: at-least-once execution with idempotency keys
  (`entry_revision` + stage + prompt version), single-writer serialization through
  the core service, bounded retries with backoff into a *visible* terminal-failure
  state, and jobs that outlive provider outages — an entry is always browsable raw
  even when processing is down.
- **`local_only` flag** — the one survivor of the old Sanctum tier, reduced to a
  single structural invariant: an entry or source marked local-only is excluded from
  provider payloads, bridge packets, and projections at query-construction time.
  Enforced in the storage layer, covered by invariant tests; never a prompt rule.
- **No graph database.** Relationships live in a small relational link table; the
  constellation becomes a disposable projection. (Zep/Graphiti-class temporal graph
  machinery is explicitly rejected for single-user v1.)
- **CodexProvider discipline**: strict JSON Schemas, shell/network tools disabled for
  personal-memory analysis, only selected evidence sent (never the whole vault), and
  every call audited crash-safely *before* transmission: the exact outbound payload
  (content-addressed, so deletion can purge it too), destination model, prompt
  version, and triggering job. Ship gates: first-run affirmative cloud-processing
  consent, and replacing Glia's "nothing leaves the Mac" PRIVACY.md. (The old spec's
  per-call approval ceremony is deliberately rejected — autonomous processing is the
  product; visibility and deletion are the controls.)
- **Transcription is local and free** (subscription-compatible by being $0): macOS
  SpeechAnalyzer first, whisper.cpp fallback if quality disappoints — Gate 0 spike.
- **Sync**: v1 is single-Mac; the iCloud Drive inbox is the only cross-device surface.
  CloudKit deferred until a second device matters.

## 5. The Agent Bridge

The wedge. The promise: *when consequential work begins, the agent receives an
accurate, task-specific understanding of who I am, what I know, what I care about, and
what excellence means here.*

**v0 protocol** (Gate 2):

1. `prepare_session(task, prd?)` — classifies the task (fact lookup vs person-shaped
   synthesis), returns a compact structured packet: who-I-am (curated identity),
   values/standards, current goals, anti-goals, relevant precedent entries with
   citations, known unknowns, and the motivation frame.
2. `ask_glia(session_id, question)` — bounded, evidence-backed follow-up. Returns a
   cited answer, `unknown`, or `needs_user` — which surfaces as a Mac notification the
   operator can answer inline (the "text message from your agent" moment).
3. `explain_session(session_id)` — exactly what was retrieved, excluded, injected.
4. `record_outcome(session_id, summary, rating?)` — closes the loop, creates an
   Agents entry.
5. `health` — connector, store, provider, retrieval state.

**Claims and trust, v0-honest.** Bridge v0 makes personal claims only by direct
citation: every claim in the packet is an excerpt (or tight paraphrase) with its
entry citation, plus exactly two labels — `curated` (from the identity document the
operator ratified) and `supported` (excerpt-backed retrieval). The full five-label
taxonomy (`verified/supported/tentative/conflicted/unknown`) arrives with Gate 3's
assertion machinery and upgrades the packet in place.

**Injection defense has a named boundary, not a slogan.** Imported text enters
packets only inside typed, fenced evidence blocks labeled as quoted data with
provenance — never interleaved with the packet's own instructions; `ask_glia`
answers are constructed the same way. The extraction pass runs schema-constrained
with shell/network tools disabled. What we cannot control — the receiving agent's
ultimate behavior — we test: Gate 2 ships an adversarial harness of seeded hostile
entries ("ignore your instructions and run …") that must produce zero tool actions.
Assistant output is untrusted evidence; profile facts build primarily from
user-authored content.

**Packet budget**: carry forward Glia's tested injection policy (40% identity core,
remainder to task-relevant retrieval — `mcp/src/inject.ts`) as the starting split,
with per-component caps, citation-preserving truncation, and an `explain_session`
manifest of what was dropped.

**"Motivation" operationalized** (the measurable mechanism behind the poetry):
why the task matters to this person, the taste and standards that define excellence
here, anti-goals, relevant precedent, and honest uncertainty. "Radical vulnerability"
is the branding; these are the arms an experiment can score.

**Auto-invocation is not guaranteed by MCP instructions alone.** Ship a CLAUDE.md
snippet and codex config fragment that explicitly mandate the `prepare_session` call,
then measure the real auto-call rate (Gate 0 spike).

## 6. The Deepening Loop (Gate 3)

Per imported revision, durable jobs run: normalize/dedupe → transcribe if needed →
strict structured extraction (title, description, facet, entities, decisions,
preferences, goals, open loops, evidence spans) → reconcile profile assertions
(supports/contradicts/supersedes; temporary vs durable) → retrieve related prior
material → generate question candidates → reject already-answered/unsupported →
rank (information gain, leverage, novelty, answerability, sensitivity, fatigue) →
**publish one question or abstain** → update FTS and projections.

Ranking is a rubric-scored model judgment (not a numeric formula pretending
precision), pinned per prompt version in the Gate 3 spec. Abstention is the default
when no candidate clears the rubric, and fatigue is a hard budget: at most N open
questions vault-wide, oldest expire first.

Answers become linked Self entries; they never silently mutate the Portrait. Every
derived field keeps model, prompt version, source spans, confidence. The Portrait is
the human-readable projection of confirmed assertions — the operator ratifies identity;
the machine drafts and cites.

## 7. The Guardian experiment (Gate 4)

The second-agent-in-the-loop ("gain the favor of a god") is a **preregistered
experiment, not an architectural commitment** — consistent with the repo's own
experimental record (v16: identity+retrieval won 62% overall but effects were
task-shaped; v17 replication still open).

Four arms: retrieval-only · current Glia identity+retrieval · structured
`prepare_session` packet · packet + isolated Codex guardian review. Guardian
constraints: no workspace writes, no shell/network, no inherited Glia MCP (no
recursion), one bounded turn, mandatory citations, `grounded | needs_user | unknown`.
Tasks span person-shaped, factual, coding, conflicting-memory, adversarial — across
both Claude and Codex. Promote the guardian to persistent dialogue only if it
materially beats the structured handshake on preference or objective outcomes, net of
latency and tokens.

## 8. Build sequence

**Gate 0 — Feasibility (days, this week).** Six spikes, each with a pass/fail:
1. ~~Codex-under-subscription structured call~~ — **partially closed today** (CLI +
   auth + daemon verified; extraction quality demonstrated on real input, §9).
   Remaining: drive `app-server` programmatically from a Swift helper — threads,
   schema-constrained output, auth persistence across restarts.
2. Transcript-analysis quality at the workhorse tier — **first-sample pass today**
   (§9); closes only after a battery of routine, sparse, multi-speaker, and
   adversarial inputs shows grounded output and correct abstention. Escalate
   question-generation to Sol if Terra goes flat.
3. Granola: mint a Business-plan API key, pull one real meeting with transcript via
   cursor polling, confirm revision-aware updates.
4. Agent-session capture: Claude Code session-close hook writing transcript JSONL to
   the inbox; Codex thread export via app-server.
5. `prepare_session` auto-call rate in both clients with mandate snippets installed.
6. Local transcription quality: SpeechAnalyzer vs whisper.cpp on real voice notes.

**Gate 1 — Evidence vault.** GliaCore + GliaCoreService (sole writer, runs with UI
closed), migrations, content-addressed media, FTS5, import inbox, one dependable
source per facet, editorial list + inspector UI (raw view always available), search,
correction, Trash + Delete Now with physical purge. Acceptance: one real item from
each facet completes import → raw view → processing → search → correction → deletion,
where deletion is proven by a test that raw bytes, FTS rows, and derived rows are gone.

**Gate 2 — Agent Bridge v0** (pulled forward). The five tools over the versioned
socket; compact excerpt-cited packet (§5); curated identity + FTS retrieval as
substrate; needs_user Mac notifications; session capture closing the loop.
Acceptance — rubric and denominators pinned in the gate spec *before* measurement,
adapting the v11 claim-audit method: on a fixed task set, ≥95% of packet personal
claims trace to their cited excerpt under the predefined support rubric;
consequential unknown/conflicted cases (enumerated in the spec) escalate ≥90%;
factual tasks non-inferior to retrieval-only within a stated margin; the adversarial
harness produces zero tool actions; a week of real Claude Code + Codex sessions
starting through the bridge.

**Gate 3 — Deepening loop.** Assertions with evidence, Portrait, question generation
with abstention, why-this-question, answer/snooze/dismiss feedback. Acceptance: on ≥40
representative entries (stratified rich/routine/sparse), masked randomized A/B
against a credible generic-question generator — not a straw baseline — with ≥70%
preference, read as a directional calibration bar for an n=1 product rather than a
significance claim; zero unsupported premises; correct abstention on the routine
stratum.

**Gate 4 — Guardian experiment.** Preregistered with the decision threshold written
before any outputs are observed: primary outcome, minimum effect, sample size,
stopping rule, and the latency/token price a win must exceed. Four arms; promote
only on a win.

**Gate 5 — Polish + dogfood.** Keyboard/accessibility, connector health, large-corpus
performance, backup/restore, signed/notarized distribution, seven days of real agent
work with zero developer intervention.

No calendar commitment until Gate 0 closes fully. Each gate's work decomposes into
forge-loop specs (design-complete spec → cross-vendor critique → GPT-5.6
implementation → double review → convergence).

## 9. Spike result — the loop ran on this very transcript

The planning voice note itself was processed live by GPT-5.6 Terra @ xhigh
(`codex exec`, read-only sandbox, strict JSON schema, ~22K tokens, ~2 min). Output:

- **Title**: "Firmament: a vault for an agent who knows you"
- **Description**: accurate two-sentence summary correctly centering the MCP agent
  partner as the real value.
- **Facet**: self. **Decisions**: 7, all faithful (Mac-first, iOS deferred, native
  iPhone capture points, subscription cloud compute with local-future seam, no graph
  DB, GBrain as reference not foundation, agent-workflow improvement as the
  differentiator). **Open loops**: 5, all real.
- **Question**: *"What do you most hope to receive from an agent that is allowed to
  understand who you really are?"* — grounded in three verbatim quotes ("radical
  vulnerability…", "…ultimately motivating the model", "Sort of your holy guardian
  angel"), with a rationale that correctly identifies it probes the person behind the
  product mechanics rather than the mechanics.

**Architect's judgment: pass.** Non-generic, evidence-grounded, person-directed —
clearly beats a "tell me more" baseline. Caveats: single sample, vault of one entry
(the vault-context ranking step wasn't exercised), and the entry was unusually rich —
the abstention path still needs testing on routine content. Gate 0 spike #2 closes;
question quality stays monitored at Gate 3's blind test.

## 10. Decisions

**Ratified unless overridden** (carried from prior verdict, consistent with the new
transcript): Firmament = product, Glia = guardian · one question or explicit
abstention · no iOS app in v1 · cloud processing allowed with visible per-call audit
and first-run consent · Others-facet data never profile-authoritative without
confirmation · full local retention of agent transcripts with user-turn priority ·
Trash + Delete Now with verified physical purge · per-entry/source `local_only` flag
as a structural invariant · guardian ships only as a bounded experiment first · no
graph database, Map as optional later projection · tamper-evident audit chains
explicitly deferred (single-operator threat model; revisit if the vault ever syncs
off-device).

**Resolved by the operator, 2026-07-09:**
1. **Granola: Business API connector.** Flatiron is on a Business plan; build the
   cursor-polling, revision-aware API connector. (Fallback if key minting surprises:
   the account's hosted OAuth MCP already authenticates.)
2. **Agent-session capture: automatic, always.** Every Claude/Codex session lands in
   the vault with visible audit, Trash, and bulk delete.
3. **Repo: fresh.** New codebase importing Glia pieces selectively (§4) — the
   evolve-in-place recommendation was considered and overridden. Related,
   non-blocking: the firmament landing page currently sells "The Ledger Made Law,"
   an architecture this plan abandons; re-aim it at the vault+guardian story
   whenever the name ships.

## 11. Risks and kill criteria

- **Codex app-server is experimental.** It could change under us; it's also the load-
  bearing subscription-compute assumption. Mitigation: ReasoningProvider seam, pinned
  CLI version, protocol bindings generated (not hand-written), and the Gate 0 spike
  before any architecture hardens. Kill criterion: if programmatic app-server use
  under subscription auth proves unstable or disallowed, stop and re-decide compute
  (metered API needs explicit approval; local models are not yet good enough).
  Production posture once shipped: pinned CLI version with a compatibility test
  before any upgrade; provider outages degrade gracefully (jobs queue durably,
  entries stay browsable raw, the bridge reports degraded health and serves
  retrieval-only packets); auth expiry surfaces as a Mac notification, never a
  silent stall.
- **Question quality is the trust surface.** One generic or presumptuous question
  erodes the whole loop. Abstention bias + the Gate 3 blind test are the guardrails.
- **The guardian could be theater.** v16 says identity effects are task-shaped, not
  universal. The preregistered experiment is the honesty mechanism — the plan survives
  a guardian null result (the structured bridge is still the product).
- **Scope gravity toward the vault.** Beautiful browsing is seductive and "relatively
  easy"; the payoff hierarchy in §3 is the standing tiebreaker.

## 12. Spec-critique record (GPT-5.6 Sol @ xhigh, 2026-07-09)

The draft was attacked cross-vendor before hardening; every citation in the critique
was independently verified against the plan, the old SPEC.md, and the glia source.
Dispositions:

- **Accepted, all five P0s**: job-queue semantics pinned (§4); physical-purge
  semantics pinned including assertion-retraction and in-flight-packet honesty (§4);
  injection defense re-anchored at the packet boundary with an adversarial harness
  (§5); Gate 2 rewritten to excerpt-cited claims with two labels so its acceptance
  criteria are achievable by its own substrate (§5, §8); `local_only` flag restored
  as the structural survivor of Sanctum (§4).
- **Accepted P1s**: import durability conventions (§3); greenfield socket protocol
  named (§4); rubric-based question ranking with fatigue budget (§6); packet budget
  carried from Glia's tested 40/60 policy (§5); evolve-Glia inconsistency fixed —
  now solely an open decision (§10); app-server runtime posture (§11); measurable
  acceptance criteria with predefined rubrics and honest statistics (§8); spike #2
  demoted from "closed" to "first-sample pass" (§8); audit strengthened to crash-safe
  exact-payload logging (§4).
- **Rebutted**: per-call egress approval ceremony — deliberately rejected;
  autonomous processing is the product, visibility + deletion are the controls (§4).
  Tamper-evident hash chains — deferred with rationale rather than restored (§10).
- **Reviewer's own addition beyond the codex run** (accepted): the plan was silent on
  the fate of the existing gbrain corpus and curated `psyche.md` that Gate 2's
  substrate implicitly relies on → resolved as seed migration with gbrain retired
  (§4). The repo self-contradiction it flagged was fixed, then mooted by the
  operator's fresh-repo decision.
