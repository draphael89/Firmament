# FIRMAMENT — Build Specification v1.1

**A private brain for one mind. Voice-first. Agent-legible. Mac-native.**

Codename: Firmament — the fixed vault of sky against which everything else moves. Rename
at will; the architecture doesn't care.

> This document is the constitution of the build. Amendments are ratifications: date
> them, cite the pressure that forced them, and keep the count low. Ratified amendments
> are recorded in the **Changelog** at the end.

---

## 0. How to read this document

This spec is written to be executed by one senior Swift engineer (or an agent swarm
supervised by one) building a personal tool for a single operator: David. It is
opinionated to the point of rudeness. Where a decision could go two ways, the decision is
made, the losing option is named, and the reason is stated. Sections 5–10 are the system;
Section 11 is the soul; Sections 14–16 are how you avoid dying in the swamp.

Vocabulary used throughout:

| Term | Meaning |
| --- | --- |
| Ledger | The canonical append-only event log. The only thing that is ever written. |
| Lens | A materialized view derived deterministically from the Ledger (Vault, Graph, Index, Constitution, Projections). Lenses are disposable and rebuildable. |
| Dream Cycle | The nightly consolidation daemon. Reads the Ledger, writes new events, never mutates. |
| The Gate | The MCP server. The only door agents enter through. |
| The Atlas | The Mac app's spatial surface — the constellation rendering of the Graph. |
| Grant | A per-agent capability defining which Projection of the brain that agent perceives. |
| Sanctum | The highest sensitivity tier. Structurally invisible to every agent and every escalation. |

---

## 1. Thesis

Firmament is not a note-taking app and not a retrieval database. It is an identity
substrate: a system that captures a mind's raw material (voice notes, text, fragments),
compounds it into structured knowledge overnight, and serves two clients as equals — the
human who authored it, through a spatial interface worth inhabiting, and AI agents,
through a consent-gated MCP surface that injects not just what the operator knows but who
the operator is.

The bet: as frontier models grow more capable, the scarce input becomes personal context
— values, taste, decision heuristics, the compressed prior of a specific mind. Systems
that hold that prior in a portable, injectable, governed form make every agent that
touches them meaningfully better aligned with their operator. Firmament is that system,
built for exactly one operator, which means every generalization tax is refused.

Three properties are non-negotiable and generate everything else:

1. **One substrate, two first-class surfaces.** A human edit and an agent write are the
   same primitive — an event appended to the Ledger. Neither surface is a translation
   layer over the other.
2. **The machine never holds the pen on identity.** It drafts, cites, and proposes; the
   operator ratifies. The Constitution's core is human-sovereign by construction.
3. **Privacy is a property of the data, not a policy of the app.** Sensitivity is stamped
   at capture and enforced at materialization. Nothing above an event's tier can ever
   perceive it — not a grant, not an escalation, not a bug in a prompt.

## 2. The Ten Tenets

These are the laws of the build. When a future decision is ambiguous, it is resolved by
whichever option violates fewer tenets.

1. **Append, never mutate.** The Ledger is immutable. Corrections are new events.
   Deletion is a tombstone event honored by every Lens.
2. **Every Lens is disposable.** Any derived state must be rebuildable, byte-for-byte,
   from the Ledger plus pinned model/prompt versions. If a view can't be regenerated, it's
   contraband.
3. **On-device by default; egress is a ceremony.** The hot path (embed, extract, recall,
   quick synthesis) never leaves the machine. Escalation to a frontier API is explicit,
   visible, minimal, and itself logged as an event.
4. **Voice is the front door.** Capture must survive a walk with a dog and no signal:
   record → transcribe on device → append → sync later. Every other plane is secondary.
5. **The human ratifies identity.** Constitution-core changes require an explicit human
   ratification event. No exceptions, including "obviously correct" ones.
6. **Agents see projections, not the brain.** Every MCP grant materializes its own view.
   There is no "raw mode."
7. **The system audits itself in-band.** Every agent access, every escalation, every
   dream-cycle write is an event in the same Ledger it describes. The audit log cannot
   drift from reality because it is reality.
8. **Deterministic before intelligent.** Structure extraction that can be done with rules
   (wiki-links, mentions, dates, hashes) is done with rules, at zero token cost. Models
   are reserved for judgment.
9. **Delete-first.** No auth, no multi-tenancy, no settings for preferences the operator
   doesn't hold, no abstraction for a second user who will never exist. When in doubt,
   don't build it.
10. **Immaculate or nothing.** The Atlas at 120fps or the Atlas doesn't ship. A janky sky
    is worse than no sky.

## 3. Prior art: what we take, what we refuse

Four systems were studied in depth. Firmament is a synthesis with strong opinions, not a
fork of any of them.

### 3.1 GBrain (Garry Tan)

An agent-operated, markdown-first brain: pages in a git repo, a Postgres/PGLite
chunk-and-embedding store, a typed link graph extracted by rules (regex/string matching,
zero LLM calls per write), hybrid retrieval, an MCP surface with scoped operations, and a
nightly multi-phase "dream cycle" (lint, backlinks, pattern synthesis, entity extraction,
embeddings, orphan detection) plus a contradiction-detection eval wired into it. At
production scale it runs ~146k pages and dozens of autonomous cron jobs.

**Take:** the dream cycle as the compounding engine and as a named ritual; zero-LLM
rule-based edge extraction on every write (this is what keeps daily ingestion free); the
contradiction sweep as a first-class consistency mechanism; "brain-ops" discipline (check
the brain before calling external APIs); the honest insight that a 24/7 daemon out-works
an agent in a chat loop.

**Refuse:** markdown files as the canonical store (structure becomes parse-over-prose;
sync via git on iOS is misery); mutation-in-place during consolidation (GBrain's dream
cycle edits pages — ours writes events and re-materializes, so consolidation is diffable
and reversible); the CLI-only human surface; server-shaped deployment (Bun, Postgres,
Render) for what should be a native process; version churn as a lifestyle.

### 3.2 Mem0

A memory layer for agents built on a two-phase pipeline: an LLM extraction phase distills
salient candidate facts from each exchange (using recent messages plus a rolling summary),
then an update phase retrieves semantically similar existing memories and asks an LLM to
choose ADD / UPDATE / DELETE / NOOP per fact. Notably, Mem0's platform later moved to a
simpler regime: single-pass ADD-only extraction with no destructive consolidation, entity
linking across memories, and multi-signal retrieval (semantic + BM25 + entity match,
fused) with temporal ranking — pushing the intelligence from write-time to read-time.

**Take:** the ADD-only lesson, which independently validates our event-log substrate —
accumulate immutably, let retrieval rank; multi-signal fused retrieval as the read-time
answer to redundancy; entity linking as a retrieval booster; the extraction-prompt pattern
(recent window + rolling context) for our signal detector.

**Refuse:** LLM-adjudicated destructive updates (an LLM deciding to DELETE your memory is
exactly the mutation-in-place trap — when it misfires it's silent and unrecoverable);
memory as a SaaS dependency; facts divorced from rich provenance.

### 3.3 Zep / Graphiti

A temporal knowledge graph engine for agent memory. Episodes (raw inputs) are preserved
non-lossily and linked bidirectionally to extracted entities and semantic edges, so every
fact traces to its sources. Its signature move is bi-temporal modeling: each fact carries
both event time (when it was true in the world: t_valid / t_invalid) and system time (when
the system learned/expired it). New knowledge doesn't delete old edges — it invalidates
them by closing their validity interval, preserving full history while keeping
current-state queries clean. Retrieval is hybrid (semantic + BM25 + graph traversal);
communities are detected via label propagation.

**Take:** bi-temporal edges and invalidation-not-deletion, wholesale — this is the correct
semantics for a mind that changes; episode↔entity bidirectional provenance (our Ledger
events are the episodes); label propagation for constellation/community detection in the
Atlas (cheap, incremental, no Leiden dependency); the framing that memory quality is a
temporal reasoning problem.

**Refuse:** a server graph database (Neo4j/FalkorDB) as a runtime dependency — our graph
is a Lens over SQLite, rebuilt from events; LLM-driven entity extraction on every ingest
(we do rules on the hot path, models only in the Dream Cycle).

### 3.4 Supermemory

Memory-as-infrastructure: a universal ingestion pipeline (text, PDFs, images via OCR,
video via transcription, code via AST-aware chunking) that separates documents (raw ground
truth) from memories (extracted, interconnected facts), a knowledge graph with typed
relationships between memories (updates / extends / derives), user profiles split into
static facts and dynamic recent context, and a "Memory Router" — a transparent proxy that
intercepts LLM calls and injects relevant context so integration is a base-URL change.

**Take:** the document/memory split (identical in spirit to our Ledger/Lens split — raw
truth below, derived intelligence above); the static/dynamic profile split, which is
precisely our Constitution core/periphery stratification, independently converged on; the
ambition that injection should be nearly free for the client (our MCP resources play the
Router's role without a proxy).

**Refuse:** cloud-resident memory of any kind; proxying inference through a third party
(architecturally incompatible with Tenet 3); opaque injection the operator can't inspect
(our injections are auditable events with visible light-trails).

### 3.5 Synthesis in one sentence

GBrain's ritual and rule-based cheapness, Mem0's read-time intelligence over an
accumulate-only store, Graphiti's bi-temporal truth semantics, and Supermemory's
ground-truth/derived-layer split — mounted on an event-sourced substrate none of them
have, rendered through a native surface none of them attempt, governed by a consent model
none of them need.

## 4. System overview

```
                  ┌───────────────────────── Mac (the Mind) ─────────────────────────┐
                  │                                                                   │
 iPhone (Senses)  │   ┌──────────┐   fold   ┌──────────── Lenses ───────────────┐    │
 ┌──────────────┐ │   │          │────────▶ │ Vault (markdown mirror)           │    │
 │ Voice capture│ │   │  LEDGER  │          │ Graph (bi-temporal entities/edges)│    │
 │ WhisperKit   │ │   │ (SQLite, │          │ Index (embeddings, exact search)  │    │
 │ Text capture │─┼──▶│  append- │          │ Constitution (core + periphery)   │    │
 │ Share sheet  │ │   │  only,   │          │ Projections (one per Grant)       │    │
 │ Light recall │ │   │  hash-   │          │ Positions (Atlas layout state)    │    │
 └──────────────┘ │   │  chained)│          └───────────────────────────────────┘    │
     ▲   │        │   └──────────┘              │                 ▲                   │
     │   │CKSync  │        ▲                    │ reads           │ reads/renders     │
     │   ▼        │  ┌─────┴──────┐       ┌─────▼────┐      ┌──────┴───┐              │
 CloudKit private │  │ DREAM CYCLE│       │ THE GATE │      │ THE ATLAS│              │
 DB (E2E blobs)   │  │ nightly MLX│       │ MCP srv  │◀────▶│ Metal sky│              │
                  │  │ consolidate│       │ (swift-  │agents│ 120fps   │              │
                  │  └────────────┘       │  sdk)    │      └──────────┘              │
                  │       escalation ─────┴─── Claude/frontier APIs (ceremonial)      │
                  └───────────────────────────────────────────────────────────────────┘
```

Data flows one way into the Ledger from capture planes and agents; Lenses are folded from
it; the Dream Cycle and the Gate both read Lenses and write events. Nothing writes a Lens
directly. The iPhone appends and lightly reads; the Mac materializes, dreams, and serves.

**Platform floor:** macOS 26 / iOS 26, Swift 6.2, strict concurrency. This is a personal
tool on 2026 hardware; backward compatibility is deleted per Tenet 9.

---

## 5. The Ledger

The Ledger is the entire truth of the system. Everything else is cache.

### 5.1 Event envelope

Every event shares one envelope. Payloads are typed per event kind. Stored as one SQLite
row per event; payload is canonical JSON (sorted keys, no insignificant whitespace —
canonicalization matters because the hash chain covers it).

```swift
struct Event: Codable, Sendable, Identifiable {
    let id: UUID                 // UUIDv7 — time-ordered, sortable, sync-friendly
    let kind: EventKind          // closed enum, see 5.2
    let occurredAt: Date         // event time (world): when the thing happened
    let recordedAt: Date         // system time: when this device appended it
    let deviceID: DeviceID       // .mac | .phone — provenance
    let author: Author           // .human | .dream | .agent(GrantID) | .system
    let tier: Tier               // .open | .personal | .sanctum   (see 5.4)
    let parentID: UUID?          // causal link (e.g., transcript → its recording)
    let payload: Payload         // kind-specific, canonical JSON (bytes stored verbatim)
    let payloadHash: SHA256      // digest of the canonical payload bytes (A7)
    let prevHash: SHA256?        // hash of previous event on THIS device's chain
    let hash: SHA256             // SHA256(canonical envelope, payload represented by payloadHash)
}
```

Two clocks, deliberately, following Graphiti's bi-temporal insight: `occurredAt` anchors
when something was true in the world; `recordedAt` anchors when the system learned it. A
voice note transcribed offline on Tuesday and synced Thursday keeps both truths. Every
temporal query in the system must be explicit about which clock it means.

Per-device hash chains (not one global chain) make sync trivial: each device appends to
its own chain; merge is a set union ordered by UUIDv7. The chains make the Ledger
tamper-evident and make "did sync corrupt anything?" a five-line verification, not a
forensic project.

### 5.2 Event kinds — the closed dozen

The single greatest schema risk is proliferation. The kind enum is closed at twelve.
Adding a thirteenth requires deleting one or writing a paragraph in this spec's changelog
justifying why the existing twelve cannot express it. Our extensibility lives inside
payloads, not in the kind system.

| Kind | Meaning |
| --- | --- |
| `capture.audio` | A voice recording landed. Payload: file ref (CAF in App Group container, content-addressed by hash), duration, capture context. |
| `capture.text` | Typed/pasted/shared text. Payload: body, source plane (composer\|shareSheet\|clipboard\|fileDrop), origin metadata. |
| `transcript` | ASR output for a `capture.audio` (parentID → it). Payload: text, segments w/ timestamps, asrModel+version, lexicon version used. |
| `annotation` | Human touched a thing: edit, highlight, pin, title, correction. Payload: target eventID/entityID, op, before/after. |
| `assertion` | A structured claim about the graph: entity upsert, edge assert, edge invalidate. Payload mirrors 6.2. Author may be human, dream, or agent — provenance distinguishes them. |
| `ratification` | Human verdict on a proposal. Payload: proposalRef, verdict (adopt\|reject\|defer), optional edited text. ALWAYS author=`.human`. |
| `distillation` | Dream Cycle output: cluster summary, periphery refresh, digest, proposal. Payload: type, content, evidence (event IDs), model+prompt versions. |
| `grant` | Agent capability created/modified/revoked. Payload: agentName, scope (tier ceiling, entity filters), resolution (public\|working\|inner), keyHash, expiry?. |
| `agent.access` | An agent touched the brain through the Gate. Payload: grantID, tool, queryDigest, eventIDs/entityIDs returned, tokensOut. Written by the Gate on EVERY call. The light-trail data. |
| `escalation` | Content left the device for a frontier API. Payload: destination, exact snippet eventIDs sent, purpose, humanApproved: Bool, responseDigest. The egress ledger. Tier ceiling: `.personal`. |
| `tombstone` | Logical deletion. Payload: target eventID(s), reason. Every Lens MUST treat tombstoned events as nonexistent. True erasure (crypto-shredding the payload) supported for legal/panic cases; the envelope row remains so chains stay valid. |
| `sync.checkpoint` | Device chain checkpoint for verification + compaction fences. |

Everything the system will ever do is a composition of these. The Dream Cycle proposing a
constitution amendment = `distillation(type: .amendment)`; you accepting it =
`ratification`; the Constitution Lens folding both into new core text. An agent writing a
note = `capture.text(author: .agent(g))` — same primitive as your thumb typing, which is
Tenet 1 made concrete.

### 5.3 Storage engine

GRDB.swift over raw SQLite. Not SwiftData, not Core Data. This workload is an append-only
table with heavy custom indexing, FTS5 full-text search, hash-chain verification queries,
and memory-mapped bulk reads for the embedding matrix — you want SQL in your hands, WAL
mode, and zero framework opinion between you and the file. One database file per device at
`~/Library/Application Support/Firmament/ledger.sqlite`, WAL, synchronous=NORMAL, page
cache tuned once and forgotten.

```sql
CREATE TABLE event (
  id BLOB PRIMARY KEY,            -- UUIDv7 bytes; primary index IS the timeline
  kind TEXT NOT NULL,
  occurred_at INTEGER NOT NULL, recorded_at INTEGER NOT NULL,   -- epoch milliseconds (A7)
  device TEXT NOT NULL, author TEXT NOT NULL, tier INTEGER NOT NULL,
  parent_id BLOB, payload BLOB NOT NULL,     -- canonical JSON bytes, verbatim (A7)
  payload_hash BLOB NOT NULL,
  prev_hash BLOB, hash BLOB NOT NULL
) STRICT;
CREATE INDEX event_kind_time ON event(kind, occurred_at);
CREATE INDEX event_parent ON event(parent_id);
CREATE VIRTUAL TABLE event_fts USING fts5(payload_text, content='');  -- BM25 leg (contentless;
                                          -- populated in the append transaction, A7)
```

### 5.4 Sensitivity tiers

Three tiers, stamped at capture, immutable thereafter (re-tiering = tombstone +
re-capture, so the history of exposure stays honest):

- **`.open`** — safe for any granted agent, escalation-eligible.
- **`.personal`** (default) — available to high-resolution grants and to escalation with
  per-request approval.
- **`.sanctum`** — health, family, the things 2 a.m. voice notes are made of. Never enters
  any Projection, never enters any escalation payload, never appears in the periphery.
  Enforced at materialization (excluded when Projections are folded), not at query time —
  an agent's universe simply doesn't contain it. Sanctum events sync (encrypted) but render
  only to the authenticated human surfaces.

Capture UX must make tiering one gesture, defaulting to `.personal`, with a long-press to
mark Sanctum before speaking. Friction here kills the system; see 9.2.

### 5.5 Sync

CKSyncEngine over the CloudKit private database, one record type (`LedgerEvent`), payloads
encrypted with `CKRecord.encryptedValues`. Append-only immutable records are CloudKit's
happy path: no merge conflicts exist because no record is ever modified; "conflict
resolution" degenerates to set union. Audio blobs ship as CKAssets; the phone may lag on
assets and still be current on text; a `sync.checkpoint` event per device per day lets
either side verify chain integrity after merge; iCloud unavailability degrades to
queue-and-wait with zero feature loss on-device.

Deleted per Tenet 9: multi-user sharing, CloudKit public DB, custom zones beyond one,
migration frameworks. If CloudKit ever offends, the substrate is portable: events are JSON;
the escape hatch is `firmament export` → newline-delimited JSON, and it ships in M0.

---

## 6. The Lenses

A Lens is a pure fold: `View = fold(events, viewVersion)` where `viewVersion` pins the fold
code, prompts, and model versions involved. Every Lens table carries the `viewVersion` and
the high-water event id it has folded through. Bump the version → the Lens rebuilds from
genesis, incrementally, in the background, while the old one keeps serving.

### 6.1 Vault — the human escape hatch

A read-only markdown mirror at `~/Firmament/Vault/`: one file per entity and per day
(`people/mark-penn.md`, `journal/2026-07-07.md`), wiki-links between them, YAML frontmatter
carrying IDs. Its jobs: greppability, Obsidian-openability, hostage-proofing, and diffing
(the Dream Cycle's nightly changes are reviewable as a plain git diff of the Vault). Sanctum
events render into the Vault under `sanctum/` with the directory excluded from Spotlight.

The Vault is not writable in v1. A file-watcher import loop is a seductive swamp — deferred
until wanted in anger, and even then edits become events, never truth.

### 6.2 Graph — bi-temporal knowledge

```sql
CREATE TABLE entity (
  id BLOB PRIMARY KEY, kind TEXT,          -- person|org|concept|project|place|work
  name TEXT, aliases TEXT,                 -- aliases feed the ASR lexicon (9.3)
  summary TEXT, summary_src BLOB,          -- distillation event that wrote it
  first_seen REAL, last_active REAL
) STRICT;
CREATE TABLE edge (
  id BLOB PRIMARY KEY, src BLOB, dst BLOB, predicate TEXT,
  fact TEXT,                               -- one-line human-readable claim
  t_valid REAL, t_invalid REAL,            -- world time: when true
  sys_created REAL, sys_expired REAL,      -- system time: when believed
  evidence TEXT                            -- JSON array of source event IDs
) STRICT;
```

Semantics lifted from Graphiti: new knowledge invalidates rather than deletes — a
superseding fact closes the old edge's `t_invalid` and opens its own. "Current graph" is
`WHERE t_invalid IS NULL AND sys_expired IS NULL`; "the graph as I believed it in March" is
a timestamp filter. Every edge carries its evidence events. Predicates are a curated list
(~20: works_at, founded, advises, invested_in, part_of, about, references, felt_during,
decided, contradicts…) — extendable via a ratified proposal only.

### 6.3 Index — retrieval

Embeddings + FTS5 + graph signals, fused at read time. Exact search, no vector database.
Chunks (~200–400 tokens) embed to Float16 vectors in a memory-mapped matrix; brute-force
cosine via Accelerate (vDSP/BLAS gemv over the mmapped matrix) answers in tens of
milliseconds at this corpus's realistic scale (well under 500k chunks for ten years of
daily capture). Revisit only if p95 exceeds 80 ms; the escape hatch is IVF sharding by
month, not a new database.

Fused retrieval (one function, used by the app, the Gate, and the Dream Cycle identically):

```
score = w₁·cosine + w₂·bm25 + w₃·entityOverlap + w₄·recencyDecay + w₅·graphProximity
```

with weights fixed in code, candidates cut to top-K per leg before fusion, and tier
filtering applied before scoring.

### 6.4 Constitution — core and periphery

- **Core** (~600–1,000 tokens; hard cap 1,500): values, aesthetic law, decision
  heuristics, how agents should disagree with the operator. Folded exclusively from
  `ratification` events. The machine literally cannot write here; it can only file
  `distillation(type: .amendment)` proposals with cited evidence.
- **Periphery** (~800–1,500 tokens): current obsessions, active projects, seasonal
  vocabulary, recent stance drift. Rewritten nightly from the trailing 45 days (half-life
  decay), each claim labeled with confidence and freshness. Never contains Sanctum-derived
  content, structurally.

### 6.5 Projections — per-grant worlds

For each grant, a Projection materializes: the Constitution at the grant's resolution
(public → outward persona; working → core + work-relevant periphery; inner → full core +
periphery), plus an Index/Graph subset filtered by the grant's tier ceiling and optional
entity scopes. Projections are physically separate tables, folded with the filter inside
the fold — a grant's retrieval literally runs against a corpus in which out-of-scope events
never existed. Revocation = stop folding + drop tables. Nothing to un-leak.

### 6.6 Positions — the sky is also a Lens

Atlas layout state (per-entity 2D coordinates, cluster assignments, brightness) is itself a
versioned, persisted Lens folded by the layout engine (11.3). Treating position as
derived-but-durable is what makes spatial memory possible: the sky is stable because its
state is owned, not recomputed on view load.

The fold is deterministic (v1.1, A1): every stochastic input is seeded from the Ledger's
genesis hash, the simulation runs a fixed-step integrator in deterministic iteration order,
and the UMAP seed+version are pinned in the Lens version. Rebuilding the brain reproduces
the same sky byte-for-byte, and the stability contract (11.3) is CI-testable instead of
vibes.

---

## 7. The intelligence stack

### 7.1 Model slots, not model names

Models churn quarterly; the spec defines slots with contracts. Every slot's identity+version
is stamped into the events and Lens versions it produces, so a model swap is a visible,
rebuildable act.

| Slot | Contract | Runs | Fill guidance (mid-2026) |
| --- | --- | --- | --- |
| embed | ≤1B params, multilingual, ≤15 ms/chunk | Mac + iPhone, every capture | BGE-M3-class or Qwen3-embedding-small, MLX 4/8-bit |
| worker | MoE ≤~35B total / ≤5B active; extraction, query expansion, quick synthesis; ~100 tok/s | Mac hot path | Qwen3.5-30B-A3B class |
| dreamer | Best model that fits 64–128 GB unified memory; judgment-quality consolidation | Mac, nightly, plugged in | 70B-dense or large-MoE class |
| pocket | 3–8B, recall Q&A over retrieved context | iPhone | Qwen/Llama small, 4-bit |
| frontier | Deep synthesis beyond local ceiling | API, ceremonial | Claude (current best) |

Runtime: mlx-swift + mlx-swift-lm, embedded in-process. No Ollama, no server, no Python —
the models are objects inside the app, loaded lazily in a ModelPool actor with a
resident-memory cap and LRU eviction.

### 7.2 The escalation gate

The only path off-device. A single choke-point API:

```swift
func escalate(purpose: Purpose, snippets: [EventID], to: Frontier) async throws -> Response
```

Behavior, in order: tier-check every snippet (`.sanctum` → structural failure, not a prompt
rule); render a Departure Card in the UI — destination, purpose, the exact text leaving,
token count; require one affirmative click (a per-purpose "always allow for 30 days" is
permitted for `.open`-tier content only); append the `escalation` event before the network
call (crash-safe egress ledger); send; append the response digest.

### 7.3 The signal path (per capture, on-device, seconds)

1. **Transcribe** (voice only): WhisperKit with the live lexicon (9.3). Emit `transcript`.
2. **Rule extraction** (zero tokens): wiki-link syntax, @mentions, known entity aliases
   (Aho-Corasick over the alias table), dates/relative dates, URLs, hashes. Emit
   `assertion` events for unambiguous hits.
3. **Worker extraction** (one worker call, JSON-schema-constrained): salient candidate
   facts (this capture + a rolling 7-day micro-summary as context), new-entity candidates,
   edge candidates with t_valid guesses, an emotional-valence tag, and a one-line title.
   Candidates above confidence θ become assertions; below θ they queue for the Dream Cycle.
   Nothing is ever auto-deleted or auto-merged at capture time.
4. **Embed + index** the chunks; refresh the ASR lexicon if new entities landed.

Perceived latency budget: transcript visible < 1.5 s after recording stops for a 1-minute
note; extraction lands silently within 10 s.

---

## 8. The Dream Cycle

Runs when the Mac is plugged in, idle, and past 02:00; a scheduled power-management wake
(v1.1, A6) ensures the Dream window survives a closed lid. Every phase reads Lenses, thinks
with dreamer, and writes only events — the entire night is a diffable set of appends,
reviewable each morning, revertible by tombstone. Phases, in fixed order, each independently
skippable and resumable:

1. **SWEEP** — hygiene. Fold unfolded events into all Lenses; verify hash chains; re-embed
   stale chunks; flag orphans.
2. **WEAVE** — entity resolution & linking. Judge the sub-θ candidate queue; propose entity
   merges (never auto-merge — `distillation(type: .mergeProposal)` with evidence; you
   ratify with one tap); assert cross-references the rules missed.
3. **JUDGE** — contradiction sweep. Sample recent assertions against nearest semantic
   neighbors; a query-conditioned dreamer pass flags temporal overlaps that conflict. True
   supersessions get invalidation assertions; genuine tensions become flagged pairs
   surfaced in the digest — a mind is allowed contradictions; the system's job is to know
   them, not erase them.
4. **DISTILL** — meaning. Re-summarize entities whose evidence changed; name and summarize
   clusters (label propagation over the current graph); refresh the periphery; detect
   recurring patterns and, when a pattern rises to identity, draft a constitution amendment
   proposal with the evidence trail.
5. **COMPOSE** — Dawn (v1.1, A2). Write the nightly script, not an essay: a structured
   `distillation(type: .dawn)` whose payload is an ordered list of scenes referencing star,
   edge, and proposal IDs — stars born with a shimmer, superseded edges closing, one proposal
   glowing toward the Chamber — each scene carrying caption text, plus yesterday's agent
   activity and egress in one paragraph, and one provocation — a question to sit with on
   today's walk. The Atlas plays the script as a ~20-second replay at first open (the
   time-scrubber mechanic pointed at a 24-hour window); the Ledger space renders the same
   script as readable text, which is the whole morning surface until the Atlas ships (M4).
   Read or watched in 90 seconds.
6. **AUDIT** — self-check. Access-pattern anomalies per grant; Lens/Ledger consistency
   counters; model+prompt version report; append `sync.checkpoint`.

Budget: ≤ 60 min wall-clock, ≤ 45 W sustained, hard token/call caps per phase with graceful
partial completion. Every phase's prompts live in versioned files in-repo; a prompt edit is
a Lens version bump for the artifacts it produces.

---

## 9. Capture planes

### 9.1 The hierarchy

Voice is primary; everything else must justify its existence. Ship exactly four planes:
voice, text composer, share sheet (iOS + Mac), file/clipboard drop (Mac). Refused for v1:
email-in, browser extension, always-on ambient listening, calendar/mail connectors (the
Gate lets agents bring that context instead — better boundary).

### 9.2 Voice capture UX

- **iPhone:** Action Button → recording starts before the app finishes launching (audio
  session warm-up in an App Intent; missing the first two seconds of a thought is a
  product-killing bug). Lock-screen widget as alternate (watch capture: backlog, v1.1). One
  glance-able screen: waveform, elapsed, a tier toggle (default `.personal`; long-press =
  Sanctum, shown in deep-indigo), stop. Live partial transcript optional and off by default.
- **Mac:** global hotkey (⌥Space) → a small floating glass panel, same anatomy. Menu-bar
  item for drag-in capture.
- Recording writes `capture.audio` immediately on stop (file first, envelope second, both
  fsynced) — transcription is always recoverable-async, never in the save path. Airplane
  mode is indistinguishable from online at capture time.
- **The echo** (v1.1, A5): two seconds after a capture, the phone ripples which stars the
  thought touched — "filed under Reflections · SKAN" — one tap to correct. Trust is built
  per-capture, not per-month.

### 9.3 ASR: WhisperKit, fed by the Graph

WhisperKit (Argmax) over Apple's SpeechAnalyzer, and the reason is a loop, not a benchmark:
Apple's API lacks custom-vocabulary support, while the Argmax stack supports boosting a
custom lexicon — and Firmament owns a living lexicon: the entity alias table. Every night
(and on new-entity capture) the Graph exports its names into the ASR lexicon, so the brain
teaches its own ears. Pin the Whisper model version. SpeechAnalyzer remains a zero-download
fallback path behind the same protocol.

Post-ASR, a single worker pass repairs disfluencies as a separate derived field (polished),
never overwriting the verbatim text — the raw words are evidence; the polish is a
convenience.

### 9.4 Text and drops

The composer is markdown-native with entity autocomplete (@ and [[). Share sheet accepts
text/URL/images (images stored, OCR queued to the Dream Cycle). Clipboard watcher is off by
default, on-demand via hotkey, never ambient.

---

## 10. The Gate — MCP surface

An MCP server embedded in the Mac app via the official modelcontextprotocol/swift-sdk
(0.11+, spec 2025-11-25): stdio transport for local clients (Claude Code, Cursor) and
streamable-HTTP bound to localhost + the Tailscale interface for the phone and any remote
agent. There is no other write or read path for agents.

### 10.1 Authentication = Grants

Each client authenticates with a bearer key minted at grant creation (key hash lives in the
grant event; plaintext lives once in the operator's clipboard). A connecting agent with no
grant gets public resolution automatically: useful immediately, intimate never
(default-deny with a welcome mat).

Every grant carries a per-grant rate limit enforced at the Gate (v1.1, A6): a looping agent
cannot mint a million `agent.access` events; excess calls receive an actionable backoff
error.

### 10.2 Tools and resources

Resources (cheap, auto-attachable):

- `constitution://current` — the stratified Constitution at this grant's resolution. Agents
  get the soul as a system-prompt fragment for free.
- `digest://latest` — the Morning Sky, grant-filtered.

Tools (all reads run fused retrieval against the grant's Projection; every call appends
`agent.access`):

| Tool | Annotations | Contract |
| --- | --- | --- |
| `brain_recall` | readOnly | query + optional time window/entity filter → top-K passages with event IDs, each ≤120 tokens, paginated |
| `brain_entity` | readOnly | name/ID → summary, current edges, aliases, recent activity |
| `brain_stance` | readOnly | topic → relevant constitution articles + periphery lines + strongest evidence passages; the "steer the model" tool |
| `brain_timeline` | readOnly | entity/topic + range → chronological facts honoring bi-temporal validity |
| `brain_note` | — | text (+optional entity refs) → `capture.text(author: .agent)`; how agents give back |
| `brain_propose` | — | structured assertion/link proposal → sub-θ queue for WEAVE; agents may never assert directly above θ |
| `brain_verify` | readOnly | event IDs → hash-chain proof; lets a paranoid agent (or operator) check integrity |

Deliberately absent: any bulk-export tool, any raw-SQL tool, any Lens-mutation tool,
`brain_forget` (deletion is a human ceremony).

### 10.3 Audit as physics

Because `agent.access` is a Ledger event, the light-trails in the Atlas (11.5), the AUDIT
phase's anomaly detection, and the weekly egress paragraph are all reads of truth, not a
logging subsystem that can rot. Revoking a grant is one event + dropping its Projection
tables; the history of everything it ever saw remains, forever, queryable.

---

## 11. The Atlas — the Mac app

This is where the tool earns "magnum opus." Everything below is in service of one feeling:
opening the app should feel like stepping into a planetarium of your own mind — quiet, vast,
precise, alive.

### 11.1 Design language: Nocturne

- **Field:** near-black with a barely-perceptible blue-violet radial breath (#07080D →
  #0B0E1A); true black on OLED external displays. No chrome. The window is the sky; controls
  appear only where the cursor lives, in glass.
- **Stars:** entities as soft-core points with subtle bloom. Size = graph centrality
  (slow-changing), brightness = activity (recency-decayed), hue = kind (people warm-white,
  concepts cyan-white, projects amber, works violet, places green-white — all within 15%
  saturation). Sanctum-derived stars render only here, ringed in deep indigo.
- **Fixed stars:** ratified constitution articles render as slightly larger, perfectly
  steady points with fine cardinal tick-marks — the sky's navigational constants.
- **Edges:** invisible by default. They fade in within a focus radius around the
  cursor/selection, as hairline great-circle arcs; predicate on hover.
- **Type:** a single quiet grotesk (SF Pro fine-tuned tracking) for UI; a serif with real
  italics for constitution and digest text. Text in the sky renders via an SDF glyph atlas.
- **Motion:** everything eases with critically-damped springs; nothing ever pops. Respect
  Reduce Motion by crossfading instead of flying. 120 Hz on ProMotion.

### 11.2 Information architecture

Four spaces, one window, ⌘1–4, all rendered within the sky where possible:

1. **Sky** — the Atlas proper (default).
2. **Ledger** — a reverse-chronological reading surface: today's captures, transcripts with
   audio scrubbing, the Dawn script as readable text. Mornings open in the Sky with the Dawn
   replay (v1.1, A2); this is where they continue.
3. **Chamber** — the Constitution: core articles (serif, numbered, dated), pending proposals
   with evidence trails, the ratification ritual (⏎ adopt / ⌫ reject / e edit-then-adopt).
4. **Gatehouse** — grants, per-agent activity sparklines, the egress ledger, Departure Card
   history.

Global: ⌥Space capture from anywhere in the OS; ⌘K omnisearch; a single voice orb (hold ⌥
and speak to ask the sky — answers stream from worker). Both render their results through
Summon (11.5); the former list/constellation duality is dissolved (v1.1, A3).

### 11.3 The layout engine — stability as the prime directive

The sky is only a map if places persist. The engine is a custom incremental force
simulation with anchored semantic initialization:

- **Init** (once per entity): project the entity's embedding to 2D via a UMAP fit computed
  over the corpus at first Atlas build; that coordinate becomes the entity's anchor.
- **Nightly** (in SWEEP): bounded relaxation — springs to anchors (strong), repulsion within
  clusters (mild), edge attraction (mild), cluster-boundary containment via label-propagation
  communities. Hysteresis: a star may not move more than maxDrift (≈ its own diameter × 3)
  per night; larger semantic shifts accumulate pressure over nights and the digest narrates
  the migration before it completes.
- **Never full re-layout.** Re-fitting UMAP produces a proposal sky, shown as an overlay diff
  you accept or reject — the one place layout meets ratification.
- Positions persist in the Positions Lens (6.6); the stability contract is tested: median
  nightly drift < 0.5 star-diameters, p99 < 3.

Zoom is abstraction, not magnification (LOD): galaxy view shows named cluster glyphs and
fixed stars only; mid-zoom resolves constellations and major stars with labels; close-zoom
resolves minor stars, edges-on-focus, and — at maximum zoom on a star — its evidence events
as orbiting motes you can open. The **time scrubber** (bottom edge, hidden until hover)
replays the sky across months using bi-temporal edge validity and brightness history. This
single control is the magnum-opus feature; it must be 120 fps smooth or it ships later
rather than worse.

### 11.4 Rendering architecture

- Metal, not SwiftUI Canvas, not SpriteKit. One MTKView (CAMetalLayer) hosted in SwiftUI via
  NSViewRepresentable; everything in the sky draws in ≤ 6 instanced draw calls.
- A persistent StarInstance buffer updated by diff each frame from an AtlasState value
  snapshot; triple-buffered; no per-frame allocation. 10k stars + 2k visible labels must hold
  120 fps on an M-class GPU with headroom.
- Picking via a small offscreen ID-buffer pass (color-coded instance IDs).
- SwiftUI owns everything that isn't the sky. The boundary is clean: SwiftUI →
  AtlasCommands in, AtlasSelection events out.

### 11.5 Summon — retrieval rendered spatially

One primitive, three former features (v1.1, A3): any retrieval summons a constellation —
the relevant stars brighten and drift forward, the answer anchors to them, the trail fades.
⌘K omnisearch results, the voice orb's sources, and agent reads through the Gate all render
through this one Metal path. A grant's read drives its trail from the `agent.access` event:
a faint comet-line sweeping from the Gatehouse point at the sky's edge through each touched
star, persisting ~90 s in live view; the Gatehouse replays any historical access as trails
on demand. When you ask the sky, your own retrieval traces in warm white — the same physics,
honestly applied to both surfaces, which is the whole thesis made visible. This is the trust
surface for the soul-sharing bet; do not cut it under schedule pressure — cut the density
glow first.

### 11.6 Weave — where works get made

The library grows its own books (v1.1, A4). Lasso a constellation → **Weave** → dreamer (or
a ceremonial frontier call through the escalation gate, 7.2) drafts an essay, rap, or thesis
from exactly those evidence events. The result lands as an ordinary `capture.text` plus a
`work` entity: a violet star wired by `references` edges into everything that made it. Zero
new event kinds, zero new predicates; the Departure Card ceremony applies unchanged when the
draft goes to frontier.

### 11.7 App architecture (Swift)

- Swift 6.2, strict concurrency, zero third-party UI dependencies. Vanilla @Observable
  state — no TCA.
- Targets: **FirmamentKit** (Ledger, Lenses, retrieval, fold engine — pure, platform-free,
  90% of tests live here), **FirmamentIntelligence** (MLX pool, pipelines, dream phases),
  **FirmamentGate** (MCP), **FirmamentAtlas** (Metal), thin app targets for macOS/iOS, plus
  **firmament** CLI (export, verify, rebuild, dream-now) sharing FirmamentKit.
- Actors: Ledger (single-writer append; fsync discipline), Folder (per-Lens fold loops
  consuming an AsyncStream<Event>), ModelPool, GateServer, DreamRunner, SyncEngineDelegate.
- The Ledger append path is sacred: capture → encode → fsync payload file → INSERT event →
  WAL checkpoint policy. A crash at any point loses at most the current utterance's tail.
- Distribution: Developer ID + notarization, direct install. Not sandboxed in v1. Hardened
  runtime on; entitlements minimal: CloudKit, network-server, microphone.

## 12. The iPhone satellite

One screen deep, four capabilities (v1.1, A5): **capture** (9.2 — Action Button latency is
the whole game), **recall** (synced Index + pocket model for offline Q&A; when the Mac is
reachable over Tailscale, hard questions stream from the Mac's worker through the Gate),
**Converse** — hold-to-talk with spoken replies via TTSKit (already inside the Argmax
package), screen-off, barge-in; the same component hosts the Mac voice orb — and the
**Morning Sky** (Dawn captions as a widget + a read-only mini-atlas: static rendered sky
image from the Mac, pannable, tappable to recall — no live simulation on the phone in v1).
When motion says a walk has begun and today's provocation is unread, one quiet notification
— "the sky has a question" — opens Converse seeded with it. Night thinks → morning asks →
walk answers → night thinks. No Chamber, no Gatehouse, no settings beyond tier defaults —
those are Mac ceremonies.

## 13. Security model (condensed)

- **At rest:** SQLite + audio under FileVault; Sanctum payloads additionally encrypted
  app-level with a Keychain (Secure Enclave-wrapped) key — crypto-shredding that key is the
  panic switch that honors tombstones physically.
- **In flight:** CloudKit encryptedValues for payloads; Gate over localhost/Tailscale only,
  never 0.0.0.0; grant keys hashed at rest.
- **Prompt-injection posture:** agents are readers of projections and writers of
  low-privilege events. A hostile agent can pollute its own notes and proposals (all
  quarantined sub-θ, all provenance-stamped, all revertible) — it cannot mutate a Lens, touch
  another projection, reach Sanctum, or trigger escalation. The blast radius is a bad note.
- The threat model honestly excludes: a compromised OS, a malicious operator, and Apple.
  n=1 clarity.

---

## 14. Milestones

Each milestone ends in something used daily, with acceptance criteria that are checkable.

- **M0 — The Spine (2 wks).** Ledger + hash chains, capture.audio/text on Mac, WhisperKit
  path, Vault folder, CLI (export, verify), CKSync of events, iPhone capture-only build.
  *Accept:* record on a walk in airplane mode → transcript appears on Mac after sync;
  `firmament verify` green across both chains; Vault greppable; zero data loss across 50
  `kill -9`s mid-capture (scripted).
- **M1 — Recall (2 wks).** embed slot + mmapped exact search + FTS + fused retrieval; rule
  extraction; ⌘K omnisearch (list form); voice-ask via worker; pocket recall on phone.
  *Accept:* "what was I thinking about X last month" answers in <2 s with correct citations
  that open the source audio at the right timestamp; retrieval identical between app, CLI,
  and Gate.
- **M2 — The Dream & the Constitution (3 wks).** Worker extraction pipeline; Graph Lens with
  bi-temporal edges; Dream phases SWEEP/WEAVE/JUDGE/DISTILL/COMPOSE (COMPOSE emits the Dawn
  script from day one, rendered as text in the Ledger space until M4); Chamber with
  ratification ritual; periphery; ASR lexicon loop live. *Accept:* seven consecutive mornings
  of Dawn captions the operator actually reads; first amendment proposal cites real evidence;
  a planted contradiction is caught within two nights.
- **M3 — The Gate (2 wks).** MCP server (stdio + HTTP), grants + projections, all seven tools
  + two resources, agent.access trail data, Claude Code connected under a working grant, phone
  tunnel escalation. *Accept:* a Claude Code session with zero Firmament-specific prompting
  demonstrably adopts constitution stances; Sanctum red-team suite (20 adversarial queries)
  leaks nothing; every access visible in Gatehouse.
- **M4 — The Atlas (4 wks).** Metal sky, deterministic layout engine + Positions Lens, LOD
  zoom, focus edges, fixed stars, Summon (one retrieval-rendering path serving omnisearch,
  the voice orb, and agent trails), time scrubber, the Dawn replay, Weave. *Accept:* 120 fps
  at 10k stars (Instruments-verified, no frame >12 ms during scrub); layout stability
  contract holds across 14 nightly cycles and a Ledger rebuild reproduces identical
  positions; the operator voluntarily shows someone the time scrubber.
- **M5 — Polish & the Ritual (3 wks).** Morning Sky widget, Converse (hold-to-talk + TTS,
  screen-off, barge-in), the echo, the provocation notification, Departure Cards everywhere,
  cluster density glow, sound design, export/rebuild drills, panic switch drill. *Accept:*
  full Lens rebuild from a 6-month Ledger in <10 min; restore-from-iCloud onto a clean Mac
  reproduces the sky (positions included); a full walk conversation round-trip with the
  screen off; one week where the tool is used without touching Xcode.

Deliberately unscheduled: Vault write-back, ambient capture, image intelligence beyond OCR,
watch capture (v1.1), multi-operator anything.

## 15. Risk register — the six that can kill it

1. **Layout instability breaks spatial memory.** Mitigation: anchors + hysteresis + drift
   contract as an automated nightly metric from M4 week 1; determinism (A1) makes the
   contract CI-testable — replay the Ledger, get the same sky.
2. **Dream quality is untrusted → mornings get skipped → compounding dies.** Mitigation:
   everything cited, everything diffable, proposals-not-actions for anything identity-adjacent;
   track ratification rate — if <50% for two weeks, dreamer prompts (or model) get revisited.
3. **Schema creep.** Mitigation: the closed-dozen rule; predicates behind ratification; this
   spec as the constitution of the build.
4. **MLX/model churn breaks pipelines.** Mitigation: slots + pinned versions stamped in
   events; model swaps are Lens bumps with background rebuilds; SpeechAnalyzer fallback.
5. **Sync corruption or split-brain.** Mitigation: immutability makes merge = union; chains +
   daily checkpoints make corruption loud; the phone never materializes; export-to-JSON drill.
6. **Metal scope-sink.** Mitigation: the Atlas is M4, after the system is daily-useful in
   text; a hard "sky budget" of 4 weeks; cut order pre-agreed (density glow → scrub-ghosts →
   bloom → never Summon, never the stability).

## 16. Testing strategy

- **Determinism first:** golden-Ledger replay tests — a checked-in synthetic Ledger (~5k
  events incl. adversarial orderings, tombstones, tier mixes) folds to byte-stable Lens
  fixtures per view version. The Positions Lens is included (A1): seeded UMAP + fixed-step
  simulation must reproduce identical coordinates on every rebuild.
- **Property tests** (swift-testing): append-crash atomicity, sync merge = union under
  arbitrary interleavings, tier invariants ("no Sanctum-derived token in any
  Projection/periphery/escalation payload" — enforced by a scanner test with an
  indirect-inference corpus), hash-chain verification.
- **Retrieval evals:** a 60-question personal eval set run on every retrieval-weight or
  embed-model change; MCP eval set of 10 multi-tool questions run against the Gate in CI.
- **Dream evals:** planted-contradiction suite; merge precision on a synthetic alias corpus;
  periphery must-not-contain list.
- **Perf gates in CI:** capture-to-transcript p95, recall p95, frame-time histogram during a
  scripted scrub, dream wall-clock.
- **Drills:** monthly full rebuild; monthly restore-to-clean-machine; quarterly panic-switch
  (on a copy).

## 17. Appendix

### 17.1 Dependency list (complete — anything absent is refused)

GRDB.swift · mlx-swift / mlx-swift-lm · WhisperKit (argmax-oss-swift) ·
modelcontextprotocol/swift-sdk · Apple frameworks (CloudKit/CKSyncEngine, Metal/MetalKit,
AVFoundation, Accelerate, AppIntents, WidgetKit, CryptoKit). Tailscale as an environmental
assumption, not a linked dependency.

### 17.2 Example: one thought, end to end

```json
// 06:41, trail, airplane mode — Action Button pressed
{"kind":"capture.audio","author":"human","device":"phone","tier":"personal",
 "occurredAt":"2026-07-07T06:41:02-04:00","payload":{"file":"sha256:9f2c…","secs":74,
 "context":{"motion":"walking","weather":"clear"}}}

{"kind":"transcript","parentID":"^","payload":{"asr":"whisperkit-large-v3@a1",
 "lexicon":"v214","text":"…the thing about the SKAN multiplier is that Jonathan's login
 event was never an add to cart, which means the whole Alberta view is…","segments":[…]}}

{"kind":"assertion","author":"system","payload":{"op":"edge.assert","src":"ent:skan-invest",
 "dst":"ent:jonathan-penn","predicate":"references","tValid":"2026-07-07",
 "evidence":["evt:transcript↑"],"confidence":0.93}}

// 02:00 that night, Mac — JUDGE closes a superseded belief
{"kind":"assertion","author":"dream","payload":{"op":"edge.invalidate",
 "edge":"edg:multiplier-valid","tInvalid":"2026-07-07","by":"evt:transcript↑"}}

// 07:05 next morning — the Dawn caption that mentions it
{"kind":"distillation","payload":{"type":"dawn","content":"The Alberta attribution
 constellation brightened again — the multiplier belief you closed in June resurfaced
 with new evidence…","evidence":[…]}}
```

One breath into the phone; by morning it is a star with a history.

---

### 17.3 Sources consulted

GBrain repo, README, skillpack & tutorials · Mem0 paper coverage & platform v3 migration docs
· Zep/Graphiti temporal-KG paper (arXiv:2501.13956) and Zep docs · Supermemory docs, repo &
DeepWiki architecture pages · Apple-silicon local-model landscape 2026 (MLX vs llama.cpp;
Ollama MLX backend notes) · WhisperKit/Argmax docs & SpeechAnalyzer comparisons ·
modelcontextprotocol/swift-sdk.

---

## Changelog

### v1.1 — ratified 2026-07-08

Pressure: the first full review pass, held to PR standard, found one Tenet-2 contradiction,
one structural redundancy, one missing organ, and three near-free loop closures. Every
elevation is paid for by a deletion or a reuse.

- **A1 — Deterministic sky (was P0).** The Positions Lens violated Tenet 2: force simulation
  and UMAP were nondeterministic, so the sky was not rebuildable byte-for-byte from the
  Ledger. Ratified: seed all stochastic inputs from the Ledger's genesis hash, fixed-step
  integrator, deterministic iteration order, pinned UMAP seed+version. Touches 6.6, 14 (M4),
  15.1, 16.
- **A2 — Dawn.** The prose digest competed with the sky for the morning. COMPOSE now emits a
  structured replay script with captions; the Atlas plays last night in ~20 seconds at first
  open; the Ledger space renders the captions as text (and is the whole morning surface until
  M4). Touches 8 (COMPOSE), 11.2, 12, 14 (M2, M4).
- **A3 — Summon.** Omnisearch's results-constellation, the voice orb's source-lighting, and
  agent light-trails were one mechanism written three times. Collapsed into one
  retrieval-rendered-spatially primitive; the list/constellation duality is dissolved.
  Touches 11.2, 11.5, 14 (M4).
- **A4 — Weave.** The spec built the library but no bench where works get made. Lasso a
  constellation → draft from exactly those evidence events → ordinary capture plus a `work`
  entity wired by `references` edges. Zero new event kinds, zero new predicates. New 11.6;
  touches 14 (M4).
- **A5 — Loop closures.** The echo (per-capture filing ripple, one-tap correction), Converse
  (hold-to-talk walk mode with TTS, screen-off, barge-in, hosting the Mac orb), and the
  provocation notification at walk start. Touches 9.2, 12, 14 (M5).
- **A6 — Hardening.** Per-grant rate limiting at the Gate; scheduled power-management wake so
  the Dream Cycle survives a closed lid. Touches 8, 10.1.

Paid by: nebula textures drop to a cluster density glow; the omnisearch list/constellation
duality dissolves into Summon; watch capture moves to the backlog; M5 grows from two weeks to
three (mostly Converse's TTS integration).

- **A7 — Hash preimage and storage types (2026-07-08).** Pressure: M0 planning research on
  canonicalization, crypto-shredding, and cross-device verification. The event hash covers the
  canonical envelope with the payload represented by its SHA-256 digest (`payloadHash`, a new
  envelope field) — shredding a payload removes the bytes while the envelope chain still
  verifies, honoring §5.2's tombstone note and §13's panic switch. Canonical payload bytes are
  stored verbatim (BLOB) and verification re-hashes stored bytes, never a re-serialization.
  Timestamps are integer epoch-milliseconds. The FTS5 table is contentless (`content=''`),
  keyed by event rowid and populated inside the append transaction with extracted human text
  (a payload BLOB cannot back an external-content table). No product behavior changes.
  Touches 5.1, 5.3.

*End of v1.1. Amendments to this spec are ratifications: date them, cite the pressure that
forced them, and keep the count low.*
