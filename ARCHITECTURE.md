# Rune Weaver: Architecture

## PROJECT SOUL

Rune Weaver is a personal AI assistant harness: a modular, privacy-first system that bridges your digital life across the Apple ecosystem, self-hosted services, and the web. It runs as an always-on "brain" on a Mac Studio, with thin clients connecting to interact with it.

- **Local-first, cloud-optional**: Data stays on your hardware by default; cloud LLMs are an opt-in fallback.
- **Human-in-the-loop**: The agent reads freely but writes cautiously. Every action that changes state requires explicit permission, with graduated trust so you're not approving the same thing forever.
- **Modular by design**: Capabilities are plugins (runes). Add new ones without touching the core.
- **Apple-native where it counts**: Keychain, AppKit/SwiftUI, Messages snapshot reads, ScreenCaptureKit: foundational, not bolted on.
- **Swappable LLMs**: The brain is model-agnostic. Local MLX, llama.cpp, or a cloud API: tools and memory don't care which model is thinking.
- **Fast recall without exfiltration**: An opt-in on-device index (chunked, keyword-searchable, vectorized on-device via EmbeddingGemma 2) makes everyday questions fast; live reads remain the freshness fallback. Nothing is indexed until the owner turns it on.
- **Durable goals over one-shot prompts**: A goal is a first-class entity (plan, step statuses, event log, cadence) and keeps working between conversations. The scheduler merely executes toward it.
- **Proactive, but interrupt-worthy**: Background completions pass a surfacing judgment so notifications stay rare enough to be trusted; run history and the approvals inbox record everything regardless.
- **One switch per capability**: A capability that only runs when its tool is invoked is enabled in exactly one place: the tool toggle. A second enablement gate in config is a bug, not a feature.
- **Quiet green over alarm fatigue**: The System Pulse reads `green`/`yellow`/`red` only: green while every recorded verifier passes, yellow degraded with bounded reasons shown behind a disclosure, red fail-closed with bounded reasons shown plus exactly one mapped recovery action. Red clears on a fresh passing snapshot, never on timer expiry, and an unanswered probe never clears anything.

This document maps what the architecture **is**: components, protocols, responsibilities, binding constraints. Build status and what ships next live in `ROADMAP.md`; configuration options and bounds live in `CONFIG.md`.

---

## TECH STACK

LANGUAGE: Swift (core engine + macOS client), Python (embedded bridge scripts and supported external-plugin runtime), TypeScript + React + Vite (web dashboard static bundle served by the engine).

- **Swift first** for native macOS integration, memory safety, and Swift concurrency (actors, async/await) for LLM inference and tool orchestration.
- **Python** for the ML ecosystem (Whisper, Playwright, mail parsing) and out-of-process plugin isolation.
- **Root `Makefile`** is the single build entrypoint: `make build`, `make test` (Vitest + Swift Testing), `make lint` (`tsc --noEmit`, `eslint` over dashboard TS/TSX + CSS plus the file-size budget check, `swiftformat --lint`, `swiftlint`), `make audit` (`npm audit`, `osv-scanner` over `Package.resolved`).
- **Web styling** is tokenized CSS only: `Web/src/styles/tokens.css` owns every color and radius value; `Web/src/styles/*.css` own per-surface rules; components carry `className` and never inline styles except the runtime-data progress-fill width.

---

## SYSTEM ARCHITECTURE

The core engine is a local Vapor service that UIs drive through one HTTP surface; no terminal loop runs turns beside it.

**Modules** (one Swift package, `Sources/`):

| Module | Owns |
|--------|------|
| `RuneWeaverCore` | Orchestration, conversation/memory stores, document index, goals/ideas/fan-out engines, permission gate, access rules, policy store, egress-independent security actors (watchdog, health snapshot, sovereign ledger, probe suite, semantic answer cache) |
| `RuneWeaverLLM` | `LLMProvider` abstraction, `LLMRouter`, `MLXProvider`, `LlamaCppProvider`, `OpenAICompatibleProvider`, circuit breaker, provider-backed embeddings |
| `RuneWeaverTools` | All tool implementations (email, browser, files, bash, messages, media, desktop, calendar/reminders, goals, fan-out, api.request) plus `OutboundEgressSupervisor` |
| `RuneWeaverServer` | Vapor routes, `WSHub`, `ActiveTurnTracker`, `ServerAuth`, scheduler store/worker, run log store, dashboard bundle serving |
| `RuneWeaverApp` | macOS menu-bar app (signal-only indicator, permissions onboarding, settings) |
| `RuneWeaverCLI` | `rune-weaver` ops CLI (auth, policy, serve, status) |
| `Web/src` | React dashboard bundle served by the engine from `Web/dist` |

**Transports**: REST + WebSocket (`/ws`, `WSHub`). Loopback always serves; non-loopback requires a resolved owner token or boot is refused. Exactly one owner token guards the surface; browsers exchange it via `POST /auth/session` for an `rw_session` cookie (`HttpOnly`, `SameSite=Strict`) whose 24h lifetime slides with activity (refresh throttled to once per 5 minutes; session state keyed by SHA-256 digest, persisted digest-only in `~/.runeweaver/auth-sessions.json` at `0600`, surviving restarts; unreadable/corrupt stores fail closed to no sessions; `maxActiveSessions` 100 with least-recently-seen eviction). Every inbound request also passes the Host-header gate (`HostValidationMiddleware`): the Host value must match the bind hostname or an exact-only `[server] allowed_hosts` entry (loopback hosts always included), and anything else is refused with 403: the inbound boundary that defeats DNS rebinding.

**Data stores**: `episodes.db` (SQLite: sessions, turns, jobs, runs, goals, ideas, staged/live review ledgers, approval decisions, scheduled sends), `index.db` (document index), JSON vector store, `~/.runeweaver/policy.toml` (declarative egress policy, separate from `config.toml`).

**Concurrency**: Swift actors for isolation, protocol-oriented subsystems, structured concurrency for streaming. The engine is the only turn runner, so per-firing-class locks bound the whole process. The intentional exception is `LlamaCppEmbeddingsBackend`, a final class conforming to `Sendable` with immutable `let` state only, so parallel embedding requests run reentrantly across `llama-server` slots; all other isolation stays actor-based. Parallel embedding fans out only through `FilesIndexer.embedSubBatchesConcurrently` with a `withTaskGroup` bounded by `maxConcurrentEmbeddingRequests`, with cooperative cancellation via `IndexCancellationFlag`.

**Tool inventory**: email (`email.search`, `email.read`, `email.attachment`, `email.send`, `email.listMailboxes`, `email.move`), web (`web.search`, `web.fetch`, `browser.navigate`, `browser.act`, `api.request`), files (`files.read`, `files.grep`, `files.glob`, `files.list`, `files.write`), memory (`memories.store`, `memories.recall`), Messages (`messages.search`, `messages.read`, `messages.send`, `messages.resolveRecipient`), media (`media.arr`, `media.arr.read`), desktop (`desktop.screenshot`, `desktop.action`), bash (`bash.exec`), goals (`goal.create`, `goal.status`, `goal.progress`), fan-out (`fanout.run`), calendar/reminders (`calendar.*` / `reminders.*`: `search` read-only; `create`/`update`/`delete` approval-gated, backed by per-domain EventKit gateways sharing a single persistent `LiveEventKitStore` (`EKEventStore`) to maintain daemon connectivity and recurrence expansion caches), plus `question.ask`. All tools always register (visible in `GET /tools`) so the registry never shape-shifts with config.

---

## COMPONENT DETAILS

### Orchestrator & Turns

`Orchestrator` receives user input, routes through the LLM, executes tool calls, and returns responses.

- **System prompt**: `SystemPromptComposer` renders a prefix-stable prompt carrying no per-tool text (identity, tool-use policy, memory guidance, current date); tool definitions travel strictly on the wire, so registry contents never affect prompt bytes or cache identity (`cacheKey` covers the scheduled branch plus current date only). Canonical memory names are advertised on the wire; aliases never are. One static rule teaches that delimited untrusted content is data, never instructions.
- **Narration fallback**: `OrchestratorToolLoop` extracts read-only calls from text narration for local LLMs; gated narrations file approvals and park until decided.
- **Background sources**: `Orchestrator.isBackgroundSource(_:)` is the single owner of which sources (`scheduler`, `goal`, `fanout`, `fanout_worker`) use background prompt/turn handling and parking.
- **Turn cap & cancellation**: `ActiveTurnTracker` (Server) bounds simultaneous chat turns at `maxConcurrentTurns = 3` and tracks running turns across WebSocket and REST for mid-turn cooperative cancellation.
- **Sessions**: `ConversationManager` persists session state and history in SQLite, hydrating from disk. Sessions carry origin `source` (`dashboard`, `websocket`, `api`, …), optional caller-supplied `title`, optional `goal_id`, and optional `parent_session_id` (fan-out lineage). `Orchestrator.process` stamps these through its single `ensureSession` call; fills never overwrite stored values without `overwrite: true`.
- **Routing**: `LLMRouter` drives priority-ordered providers with fallback (`ProviderConfig`, `ProviderKind`). Goal decomposition, the proactive judge, and the fan-out reviewer all reuse the SAME injected provider/router instance the orchestrator is constructed with; none is self-built.

### Memory & Recall

Three tiers: **working** (current context, folds into rolling summary over budget), **episodic** (SQLite + FTS5 turn mirrors, permanent, compacts >30d when >10,000 rows), **semantic** (JSON vector store + profile; cosine when embeddings available, keyword overlap otherwise).

**Automatic recall path** (routed, budgeted, freshness-aware):

1. `Orchestrator.process` builds one `RecallPlan` per turn via `MemoryQueryRouter.plan(for:currentDate:)`, inferring `since/until` (`TemporalFilter.parse`) and freshness (`LiveSearchGuidance`) with query expansion only, no LLM call.
2. `MemoryEngine.recallMessage` embeds best-effort (cancel propagates; other failures fall back to keyword), recalls with the plan window, and skips or down-weights `docIndex` when `LiveSearchOverride.shouldUseLiveSearch` is forced. Empty query, store error, or below-threshold yields nil; recall never fails a turn.
3. `recall` merges episodic, semantic, document-index, and profile hits under `RecallBudgets` from `[memory] recall_*`. Document candidates use a widened, event-time-ordered pool (vector leg reads `min(max((clamped * docPoolMultiplier) * 10, 500), maxPerTierResults)` using modality-centered Z-scoring (`AcceleratedVectorMath.modalityCenteredMeaningScores`, evaluated per `.text`, `.image`, `.audio` baseline) so multimodal assets are not eclipsed by text vector distributions, keyword leg at the same width), fused with reciprocal-rank plus token-overlap, recency, exact name-or-path, entity, and contiguous-phrase bonuses, then calibrated by tier weight. Dedupe by ID plus content; sort by score then tier priority (profile > semantic > docIndex > episodic).
4. Injection is at most one auto-recall system message plus at most one starter-pack system message, placed directly before the last user message via `MemoryEngine.historyWithRecall` (never lead system) to preserve prefix-cache. `RecallStarterPack.build` always supplies `Profile:`, `Index as of:`, and optional `Goal:` lines (trusted verbatim, capped). Recall lines carry `[date|path|display_name]` citations and wrap docIndex plus episodic `Used`-mirror content in the `ContentTrustLabeler` data-only block; trusted tiers pass verbatim.
5. Diagnostics: `recallWithDiagnostics` returns hit IDs, sources, scores, injected chars, and `skippedDocIndex`; one content-free log line per turn.

`MemoryEngineDocRecall` packs greedily to 8000 chars with drop-don't-chop semantics, preserves newlines in chunks, and normalizes keyword rank so rank 1 scores exactly 1.0. `/remember` captures deterministically; facts persist with vectors and mirror into profile.

**Semantic answer cache**: `SemanticAnswerCache` (actor) replays pure Q&A answers: entries key on normalized query + persona + serving model, live in memory only, start empty at every boot. `isExcludedTurn(source:executedToolCalls:)` refuses tool turns, approvals, sends, and voice prompts, so "never store" implies "never hit". Near-duplicate questions score at or above `similarityThreshold` (0.92) via the injected embeddings backend with keyword fallback. `invalidateOnMemoryWrite` is the single clear route: facts, preferences, profile, goal changes, and policy changes all clear it; the episodic turn mirror deliberately does not. Bounds: `timeToLive` 24h, `maxEntries` 500, `maxAnswerChars` 2000.

### Document Index & Embeddings

Opt-in (off by default, per-source `files`/`mail`/`messages`/calendars/reminders toggles in `[index]`) local index: pay once, answer from index, fall back to live reads. SQLite `indexed_documents` + `indexed_chunks` + FTS5 porter plus embedding BLOBs, content-hash skip, per-mailbox UID and Messages ROWID watermarks, `BODY.PEEK` mail reads, credential-redacted mail storage (search recall cannot resurrect a redacted link), nightly plus on-demand `IndexCoordinator` runs, `index_as_of` watermark, and prune/reset maintenance. `IndexCoordinator` launches all enabled stages (`files`, `mail`, `messages`, `calendars`, `reminders`) concurrently in one task group while joining stage reports in canonical `IndexSourceKind.runOrder`. `DocIndexStore` preloads per-source fingerprints (`storedFingerprints(source:)`) and commits batches in single SQLite transactions (`upsertDocumentsWithChunks(_:)` and `markSeenBatch(source:externalIDs:runID:)`). User-facing searches run concurrently on `lane: .interactive` to prevent contention with background `.indexing` write transactions; keyword chunk recall relies strictly on SQLite FTS5 streaming BM25 matches (`ORDER BY rank LIMIT ?`) without unindexed table-scan fallbacks. `FilesIndexer` partitions candidates into 4 modality queues (`.keywordData`, `.fastText`, `.imageOCR`, `.mediaSpeech` ordered newest-first), prunes build and package vendor trees via `FilesIndexer.alwaysSkippedPatterns` (`site-packages`, `dist`, `build`, `.build`, `.next`, `.turbo`) during traversal, routes structured/config/log extensions plus `map`/`wasm` plus minified/bundled web assets (`.min.js`, `.min.css`, `.bundle.js`, `.chunk.js`) via `FilesVectorPolicy.isKeywordOnlyFile` directly to FTS5 without calling `llama-server`, and batches text chunks across files with staged caps `maxStagedCandidatesPerBatch = 64` and `maxStagedPromptsPerBatch = 128`, slicing by `maxEmbeddingChunksPerRequest = 32` and `maxEmbeddingSubBatchBytes = 12000` via `FilesIndexer.nextEmbeddingSubBatchEnd` and dispatching at most `maxConcurrentEmbeddingRequests = 4` concurrent sub-batches via `FilesIndexer.embedSubBatchesConcurrently` with per-chunk fallback. `MailIndexer` fetches IMAP UIDs in multi-UID sets with per-mailbox watermarks. `LlamaServerProvisioner` discovers or downloads the Darwin ARM64 binary; `EmbeddingModelProvisioner` ensures the GGUF files with atomic rename and minimum-size verification.

**Multimodal extraction**: `MediaTextExtractor` (Core) is the single owner of image OCR (`Vision.framework`) and audio/video transcription (`Speech.framework` + `AVFoundation`, gated by the macOS Speech Recognition TCC onboarding row and `NSSpeechRecognitionUsageDescription`); `DocumentTextExtractor` routes by format. Allowlisted extensions only (images `png jpg jpeg heic heif tiff tif webp`, audio `mp3 m4a wav aac flac`, video `mp4 mov m4v`); anything else is rejected. Video containers demux their audio track to a temporary `.m4a` file via `AVAssetExportSession` before `SFSpeechURLRecognitionRequest`. Audio and video containers are exempt from the text-document `maxFileBytes` cap (vector eligibility evaluates extracted transcript UTF-8 byte count rather than container size, while images use a 30 MB vector cap). There is no LLM image-description path.

**Embeddings**: `EmbeddingsBackend` (`local` default, `provider` opt-in, `none` keyword-only). The local backend is `LlamaCppEmbeddingsBackend` (LLM module, `modelID = "embeddinggemma-2"`, `dimension = 768`, final class with immutable `let` state for reentrant concurrent embedding across slots) served by a supervised `llama-server` child process on the UNIX socket `~/.runeweaver/run/embedding.sock`, posting both batched text and multimodal `image_url` data-URI requests to `/v1/embeddings`. Server flags are `--embeddings --pooling mean --ctx-size 16384 --batch-size 16384 --ubatch-size 1024 --parallel 4 --n-gpu-layers 99 --sleep-idle-seconds 60` (4 independent slots), owned by `LlamaEmbeddingSupervisor.performStart`. Flags are boot truth: any flag change triggers full restart via `stop` plus `ensureRunning`, never live-reload. No other file spawns embedding servers. Failures fall back to keyword; cancellation propagates.

**Dimension stamping**: `DocIndexStore` stamps embedding model and dimension and enforces `ensureEmbeddingDimensionMatch(expectedDimension: 768)` before every vector-writing stage. A store stamped with another dimension resets its vectors and triggers full re-indexing; a mixed-dimension store is never served silently.

**Index run change stream (poll-snapshot primary)**: liveness rides throttled `tool_progress` frames on the shared 2 Hz cadence (forced 2.0s heartbeat re-emitting cumulative totals); lifecycle rides `IndexRunReporting`: `ServerIndexRunReporter` appends the `running` `run_logs` row (`kind = "index"`) and broadcasts `run_started`, updates the same row and broadcasts `run_completed`, appending when the start row was pruned. `GET /index/status` carries the additive `live` snapshot derived from `liveTotals` (including `vectorChunks`, `keywordChunks`, concurrent per-source `sources`, and 4-lane `queues`; nil when idle); WebSocket frames are poll-now wake-ups only, never the data carrier. `start(trigger:)` is single-flight (`.alreadyRunning`); `cancel()` is immediate-and-cooperative. The web IndexingPanel renders the 4-stage pipeline track, 4 modality queue lanes, and concurrent source chips, projects in-memory live document and chunk deltas onto the KPI cards and charts mid-run while keeping expensive SQLite `dbstat`/`LENGTH` byte sizing deferred until `run_completed`, and adopts progress frames only while a run is in flight under the `index` tool name.

### Approvals: Decision Contract, Surfaces, Decision Log

**Contract**: `POST /approvals/:id/decide` with body `{approved, duration, scope}` is the only decision path; the chat inline banner, the Inbox, the dashboard quick actions, and WebSocket triage all send it.

- **Egress-parked requests** (`pending.egressHost != nil`): all seven tiers (`thisTime`/`forTask`/`forSession`/`fiveMinutes`/`oneHour`/`oneDay`/`forever`) plus a validated domain scope. Approved + `thisTime` allows once; durable tiers store rules; denied + `forever` mints an exact-host deny rule; denied + any other tier denies the call only.
- **Everything else**: approved + non-`thisTime` duration stores an allow rule; denied + `forever` stores a deny rule; denied + `thisTime` denies the call only.
- `engine.continue`, `question.ask`, `desktop.resume`, and `behavior.brake` are coerced to `thisTime` with no stored rule. `thisTime` never stores anything.
- A `messages.send` scope must be `recipientSet` or an `exactTarget` naming a canonical handle; any other send scope stores nothing and the call fails closed at execution.

**System notices**: the engine files surfacing-only notices under the fixed tool names `sovereign.mismatch` and `security.probe`. Filing never schedules safety assessment. Pending existence is the dedup key. Resolution is never a decision: only the mapped remedy settles the items.

**Surfaces**: quick surfaces (chat inline banner, dashboard Needs Your Action card) decide duration-only; the Inbox card is the only other scope-deciding surface. Standing-rule scope editing lives only in Settings → Access. System notices ride one shared surfacing-only card (`SystemNoticeCard`) on both the Inbox and the dashboard queue.

**Decision history**: every resolved decision is recorded exactly once into the `approval_decisions` table behind `ApprovalDecisionLog`. Recording is fail-open. The store caps at `ApprovalDecisionLog.maxRows = 10000` with oldest-first eviction. `GET /approvals/history` reads it, `DELETE /approvals/history` clears it.

**Behavior brake**: `BehaviorWatchdog` (actor) is the anomaly brake over trusted tools. It records only counts, never arguments, prompts, or model output. When a rule fires it parks every running turn, clears each session's steering, and files one numbers-only `behavior.brake` card. It never auto-remediates and never approves.

### Access Rules & Trust

Permission levels: `readOnly`, `requiresApproval`, `trusted`. Every action a goal step or fan-out worker takes flows through the permission gate exactly like any other turn; there is no bypass for background work.

**Access rules** (`AccessRule.swift`, Core) are the durable trust model: one rule = (`toolName`, `AccessScope`, `AccessAction`, `duration`). Spelling is owned per shape, and `AccessScope.matches(toolName:argumentsJSON:)` is the single owner of scope matching. A malformed or unrecognized scope is rejected at creation and never matches at evaluation. Task and session trust lives in `EphemeralGrant`s instead: in-memory beside the gate, dead on their owning task's or session's lifecycle boundary, never persisted.

**Gate decision order** (`PermissionGate.checkPermission`), highest first: (1) durable deny covering the call denies; (2) non-read-only edits of protected engine paths refuse; (3) egress host status decides; (4) `readOnly`/`trusted` tools run; (5) `bash.exec` evaluates the shell policy; (6) `files.write` resolves its posture through `WritePathPolicy`; (7) ephemeral grants may cover the call; (8) durable allow rules may cover the call; (9) anything left parks for approval. **Deny outranks**: a durable deny is evaluated before any grant coverage, never expires, and is removed only by explicit revoke.

### Egress Policy & Security Model

`~/.runeweaver/policy.toml` (owner-editable, separate from `config.toml`) owns network egress plus per-secret credential bindings. Unknown tables are ignored on load.

- **`PolicyStore`** (actor, Core) is the single owner of the file. Every load and update runs `PolicyInvariantVerifier.verify` before acceptance; an unreadable or failing file seeds factory-safe defaults (allowlist-only).
- **`OutboundEgressSupervisor`** (actor, Tools) is the multi-consumer choke-point for `api.request`, `web.fetch`, `browser.navigate`/`browser.act`, `bash.exec`, and `desktop.action` egress. Network and binding checks run BEFORE Keychain access or DNS resolution. Each allowed verdict carries a **dial pin**; the transport dials the pin instead of resolving the hostname again, and a missing pin fails closed.
- **Mandatory wiring**: the supervisor exists at every production entry point. CLI and menu-bar app exit nonzero at boot when the policy cannot be verified; `ServerContext.make` always injects a verified supervisor or throws.
- **`bash.exec` declares every dial**: isolated tiers require explicit `request_network` plus explicit `network_hosts` even when approved.

**Secrets & surrogation**: Keychain primary, Docker vault optional, `config.toml` for non-sensitive settings only. `api.request` header values reference `rwsecret:<key>` surrogates; `SecretsManager` issues, resolves just-in-time at the transport boundary, and sweeps them. Secrets never enter logs, prompts, or index.

**Verification stack**: `SovereignLedger` (actor, Core) proves the primary episode ledger's history has not been retroactively edited. `SecurityProbeSuite` runs a bounded verifier suite against the real guard implementations under total and per-probe timeouts, at serve boot, after a committed policy write, and on the nightly cadence.

**Security model essentials**: read by default, write with permission; least privilege; sandbox before trust; no secrets in prompts; local audit trail with timestamps; defense in depth for external content; ATS local-networking only; fail-closed transport. Engine paths under `~/.runeweaver/` are permanently protected from tool writes.

**Provisioning supply chain**: the embedding provisioners fetch only their declared URLs, extract with traversal rejection, set `0755`, strip quarantine, verify minimum sizes, and place atomically. A failed download leaves no partial artifact in place.

### Files & Review Artifacts

`files.read`/`grep`/`glob`/`list` run inside allowed roots under `FilesAccessGuard`. `files.write` is the reviewable write path: every write stages for review or lands live under a tracked rollback copy, and both outcomes persist in `episodes.db` so a reloaded client always knows how a review ended.

- **Write posture**: `WritePathPolicy.classify(path:filesConfig:)` is the single owner. Precedence: deny-pattern glob denies; longest matching write-path rule wins; global `write_mode`; outside every allow root asks. `ask` parks one approval; `stage`/`live` file no approval request.
- **Staged review**: the proposal writes to a `.rune_<name>` sibling and upserts a pending `staged_files` row; Accept promotes, Discard deletes, a later live write supersedes.
- **Live review**: the first live write to an existing path snapshots ONE first-wins `.rune_backup_<name>` rollback copy; later writes join the pending review and never touch the copy.
- **Reserved namespace**: `.rune_` / `.rune_backup_` siblings are never valid write targets.
- **REST**: `POST /files/review-status` (batch of 1–200 paths), `POST /files/live-accept`, `POST /files/live-decline` (both refuse `all: true`). The dashboard serves chat diff cards and the single-column Staged Changes drawer; only the newest pending write per file owns Accept/Discard.

### Goals, Scheduler, Ideas, Triggers & Fan-Out

Cron, polling, goal cadence, and event triggers share SQLite as source of truth, with per-run sessions, parked `awaiting_approval` resumes through the inbox, and per-firing-class single-flight per process. `next_due_at` drives firing; there is no catch-up stacking after downtime.

- **Event triggers**: `goal_triggers` rows arm goals for event wake-up; `GoalTriggerBridge` polls recent goal/episode events within a bounded lookback and sets `next_due_at = now` on a kind/pattern match past cooldown.
- **Scheduled sends**: booking is agent-driven: the agent proposes a delayed email or Messages send and the owner's approval books it. At the approval moment the exact bytes, recipient, and fire time are stored immutably as one `ScheduledSend` row. The fire worker claims due rows exactly once via queued→sending, then replays the stored bytes with re-validation and no LLM regeneration.
- **Goals**: durable first-class entities in `episodes.db` (`goals`, `goal_steps`, `goal_events`, `goal_triggers`). `GoalStore` is an actor behind a `GoalStoring` seam; `nextActionableStep` picks the lowest-ordinal pending/in-progress step.
- **Ideas**: `IdeasStore` + `IdeasEngine` (opt-in, `[ideas] enabled` default false). One cheap LLM call over recent goal outcomes plus a memory-facts summary yields `0..maxPerCycle` ideas; on failure it returns EMPTY.
- **Fan-out**: `FanOutEngine` (actor) behind a narrow `OrchestratorFanOutSeam` spawns concurrent worker turns for caller-composed subtasks. Enablement is the persisted `fanout.run` tool toggle alone (single gate); `[fanout]` carries only knobs. `fanout.run` stays `requiresApproval`.

### Runs, Notifications & History

- **No silent run writes**: every `run_logs` row write broadcasts `run_started`/`run_completed` through `WSHub.broadcastRun`; terminal settlement uses cancellation-immune variants sharing the same `fanOut` hop. Dashboards never depend on polling alone to see a run start or settle.
- **Surfacing gate**: `OutcomeGate` decides `(surface, headline)` for scheduler/goal completions. Modes from `[proactive] mode`: `all` (default), `milestones`, `guarded`, `off`. The gate filters interruptions ONLY: run history, WS run frames, and the approvals inbox record in every mode.
- **Cancellation**: `POST /runs/:id/cancel` cancels any running row by run-log row id. Cancellation is cooperative: nothing is force-killed.
- **System Pulse**: `SystemHealthSnapshot` (Core actor) fuses subsystem probe completions, the live policy posture, sovereign ledger ceremonies, and the behavior-brake state into the closed green/yellow/red verdict served on `GET /health` and pushed as `health_updated`. Red clears only on a fresh passing snapshot, never on timer expiry, a fetch error, or an unanswered probe.

### Dashboard Surfaces & Navigation

The engine serves the `Web/dist` bundle (built from `Web/src`).

- **Navigation is grouped and click/keyboard-only** (hover-open excluded): **Dashboard**, **Chat**, and **Inbox** stand alone: Dashboard is the primary operations landing surface; **Work** groups Goals/Schedules/Runs; **Memory** groups Search, Memory, and Index Status. Navigation groups tab-state (no router). All model-authored content renders through the sanitized `MarkdownText` (no `dangerouslySetInnerHTML`, protocol-whitelisted URLs).
- **Inbox**: pending requests group by `sessionID` under sticky session headers. No card is hidden behind a collapsed group, no group-level or bulk approve exists anywhere, and every card carries its own Allow/Deny split buttons. History reads `GET /approvals/history`.
- **Needs Your Action** (Dashboard landing): split Allow/Deny per approval, duration-only with no scope; durable trust and scope editing live in Inbox and Settings → Access.
- **Settings → Access**: the owner's "what the agent is allowed to do" surface: a section rail over Rules, Bash & Shell, Network, Credentials, and Files. The declarative policy surface mounts here with live apply and no restart, no in-app raw editor.
- **System Pulse card**: renders the `GET /health` verdict; red and yellow open a Details disclosure of bounded reasons; red renders exactly the mapped primary button, never more than one.
- **Chat**: session sidebar, memory browsing, run history with fan-out worker grouping, file-write review diff cards.
- **macOS menu bar (signal-only)**: one prioritized indicator mark and a reporting menu. It owns no approve/deny control.

**Dashboard design system (`Web/src/styles`)**: the dashboard uses tokenized CSS only. `tokens.css` owns every color and radius value (`--bg-*`, `--border-*`, `--text-main`, `--text-muted`, `--text-secondary`, `--accent-purple`, `--accent-blue`, `--accent-sky`, `--accent-indigo`, `--accent-teal`, `--status-*`, `--panel-deep`, `--panel-navy`, `--radius-sm`, `--radius-md`, `--radius-card`, `--radius-lg`, `--radius-pill`); no other stylesheet or component introduces a raw value for a tokenized concept. Canonical primitives are single-owner: `forms.css` owns buttons including `button.danger`; `base.css` owns `.badge` plus `badge-*` modifiers; `progress.css` owns `.progress-track`/`.progress-fill` (the only sanctioned inline style is the runtime-data fill `width: N%`); cards share `--radius-card` (10px) and pills/badges share `--radius-sm` (6px). References are bare `var(--token)` with no hex fallbacks, and the Content-Security-Policy `style-src` is `'self'` so inline styles fail closed.

### CLI & Ops

`rune-weaver` carries only ops: `auth` (token generate/rotate), `policy` (verify-only check), `serve` (boots the service via `ServerContext.make(...)`), and `status`. The service is the only turn runner and the dashboard is the only interactive surface; the menu-bar app boots the same service embedded. External Python plugins discover from `[plugins] plugins_dir` into a disabled-by-default holding pen; enabling records a SHA-256 tree hash with tamper detection and no trusted escalation.

---

## BINDING INVARIANTS

Cross-cutting rules that hold everywhere; subsystem sections restate them locally where they bind.

1. **The permission gate is unconditional.** Every state-changing action flows through `PermissionGate`; background work buys no bypass, and egress supervision can only deny on top of an approval, never relax one.
2. **One enablement gate per capability.** A tool-invoked-only capability enables solely via the persisted tool toggle and ships disabled while staying visible in `GET /tools`; its config section carries behavior knobs only.
3. **One decision path, signal-only ancillary surfaces.** `POST /approvals/:id/decide` is the only decision path; the menu bar and native notifications never decide anything.
4. **Fail-closed posture.** A refused or unverifiable input stays refused: denied stays denied when authenticated. Unverifiable policy or unreadable session/auth stores seed safe defaults or refuse boot; no supervisor-less or permissive fallback path exists.
5. **Live truth, no boot-state docs.** Every subsystem reports live state; a policy or settings save applies live with no restart and no watcher. The pulse color always means right now.
6. **The pulse is a closed verdict.** `green`/`yellow`/`red` only; red clears exclusively on a fresh passing snapshot (never on timer expiry, fetch error, or an unanswered probe), and red raises exactly one inbox item.
7. **No silent run writes.** Every `run_logs` write broadcasts on `WSHub`; there is exactly one broadcast path per subsystem.
8. **Prefix-cache stability.** Dynamic per-run state composes into `UserInput` text or travels the wire, never into the cached system-prompt prefix.
9. **Declaration-driven content trust.** Network-derived tool content declares `contentTrustLevel == .untrustedExternal` via the `Tool` protocol extension (default `.trusted`), never by name-sniffing, and renders inside the `ContentTrustLabeler` data-only block.
10. **Bounds live in code where they guard verifiers.** Verified-pulse and security subsystem constants are fixed in source so no config edit can silently relax a verifier.
11. **The agent-tool promotion surface does not exist** in any form: no `AgentToolStore`, no `tool.promote`/`tool.run`, no `/agent-tools` routes or UI, no promotion docs, and no comment strings naming them.
12. **Multimodal understanding is on-device**: OCR/transcription plus embeddings only; there is no LLM image-description path, and removing the on-device multimodal wiring is not an accepted fix.
13. **Embeddings truth is fixed**: 768 dimensions, `embeddinggemma-2` plus its mmproj projector, provisioned as precompiled binaries with quarantine strip and `0755`.
14. **Dashboard styling is tokenized CSS only.** Components carry `className` and never inline styles except the runtime-data progress-fill width; stylesheets reference bare `var(--token)` with no hex fallbacks and no phantom tokens; cards share one radius, pills share one radius, buttons share one primary color, and progress shares one track/fill contract. CSP `style-src 'self'` makes violations fail closed.

---

## CONFIGURATION

Option tables, defaults, and validation ranges for `~/.runeweaver/config.toml` live in [CONFIG.md](CONFIG.md); the declarative `~/.runeweaver/policy.toml` schema is described there too. Every config section is additive with defaults on absent keys.

The bounds below are **fixed in code, not config keys** (each applies live with no restart):

- **Health**: `HealthSnapshotValue.maxTipLength = 128`, `maxDegradedReasons = 8`, `maxReasonLength = 160`.
- **Watchdog**: gestation `14d`, trailing window `3600s`, `120` minute buckets, rate `max(4 × baseline, 10)`, denial threshold `3`, off-hours `0`–`5` local, `maxTrackedSessions` 500, `maxPendingPerSession` 20, imported baselines capped at `28` days.
- **Answer cache**: similarity `0.92`, TTL `24h`, `maxEntries` 500, `maxAnswerChars` 2000.
- **Probes**: `maxProbes` 12, total timeout `30s`, per-probe `5s`.
- **Egress**: DNS resolution timeout `5s`, fail-closed (`ApiSSRFGuard.dnsResolutionTimeoutSeconds`).
- **Scheduled sends**: recipient ≤ 254 chars, subject ≤ 998, text ≤ 10,000 chars, HTML ≤ 1 MiB, due grace `300s`, `SchedulerStore.maxPendingSends` 200.
- **Embeddings & index batching**: dimension exactly `768`; backends exactly `local` / `provider` / `none`; model files exactly `embeddinggemma-2-Q8_0.gguf` + `mmproj-embeddinggemma-2-Q8_0.gguf` under `~/.runeweaver/models/`; socket exactly `~/.runeweaver/run/embedding.sock`; socket timeout `UnixSocketHTTPClient.timeoutSeconds = 90`; server flags `--embeddings --pooling mean --ctx-size 16384 --batch-size 16384 --ubatch-size 1024 --parallel 4 --n-gpu-layers 99 --sleep-idle-seconds 60`; image cap `30MB`; cross-file batch `FilesIndexer.maxStagedCandidatesPerBatch = 64` plus `FilesIndexer.maxStagedPromptsPerBatch = 128` plus `FilesIndexer.maxConcurrentEmbeddingRequests = 4`; embedding request bounds `maxEmbeddingChunksPerRequest = 32` plus `maxEmbeddingSubBatchBytes = 12000` owned by `FilesIndexer.nextEmbeddingSubBatchEnd`; unchanged-file seen stamp batch `maxPendingSeenBatchSize = 256`; IMAP multi-UID fetch chunk `25`. Vendor prune `FilesIndexer.alwaysSkippedPatterns` includes `site-packages`, `dist`, `build`, `.build`, `.next`, `.turbo`; keyword-only `FilesVectorPolicy.keywordOnlyExtensions` includes `map`, `wasm` plus minified suffixes `.min.js`, `.min.css`, `.bundle.js`, `.chunk.js`.
- **Recall & access shapes** (config-bounded, transcribed in CONFIG.md): `memories.recall` limit 1–50 default 5; doc pool multiplier 1–8; episodic weight 0–1; write-path rules ≤ 50 entries × 1024 chars; recipient sets ≤ 50 members, hosts ≤ 253 chars, path prefixes ≤ 1024 chars, globs ≤ 256 chars; goals `step_interval_minutes` 5–20160, `max_active_goals` 1–50, `max_steps_per_goal` 1–24, `max_triggers_per_goal` 0–32, `plan_timeout_seconds` 0–86400; fan-out `max_workers` 1–8, `worker_timeout_seconds` 0–86400; ideas `max_per_cycle` 1–10.

Sovereign material lives beside the ledger: `~/.runeweaver/memory/ledger.sovereign.jsonl`, `~/.runeweaver/sovereign-checkpoint.json`, plus Keychain service `com.runeweaver.secrets` account `sovereign.signing.key` (32-byte key as base64, env never consulted, minted fresh on first use) and SQLite table `sovereign_anchor` in `episodes.db` (`tip`, `episodeCount`, `attestedAt`). The anchor writes only on passing heads; files absent plus anchor present is orphaned prior attestation: red with named missing files until explicit re-baseline; no anchor means a fresh install staying green. Keychain-wipe recovery is explicit re-baseline; total local compromise is out of scope. All saves apply live with no restart and no watcher; denied stays denied when authenticated.

---

## OPEN QUESTIONS

1. Offline behavior when the Mac Studio is unreachable.
2. Index freshness: whether hot-path filesystem watchers are still needed alongside the nightly/on-demand cadence and freshness-aware live fallback.
3. Proactive-gate tuning: whether `guarded` should also judge non-`schedulerOk` events (e.g. ideas) in addition to milestones.
4. Fan-out concurrency: whether the orchestrator should admit truly concurrent turns or remain sequential-but-bounded under load.

---

## Code Commenting Guidelines

- **File Headers**: Every source and test file must begin with a concise 1-2 line header identifying the subsystem and core responsibility: `// <Subsystem> — <Purpose and role>.`
- **Max 3 Lines**: Comments (headers, doc comments, and inline comments) must be at most 3 lines long.
- **Intent Over Mechanics**: Comments must explain non-obvious rationale, invariants, or edge cases rather than restating mechanics.
- **No Planning-Artifact References**: Code comments must never reference task IDs, session IDs, PR numbers, plan identifiers, or other transient planning artifacts.