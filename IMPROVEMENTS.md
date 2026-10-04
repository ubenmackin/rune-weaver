# Rune Weaver — Harness Improvement Ideas

A researched, categorized list of improvements for the in-development agent harness. Each idea includes a breakdown, why it matters, and an implementation estimate.

---

## 1. Agent Evaluation & Benchmarking Harness

**Breakdown:** Build a structured evaluation framework that lets you test the agent's behavior across known scenarios. Currently the system has run logs but no way to measure *quality* — was the answer correct? Did it use the right tool? Did it hallucinate?

- **Scenario definitions**: A JSON/YAML format describing a prompt, expected tool calls, expected answer content, and pass/fail criteria.
- **Runner**: A `rune-weaver eval` CLI command that runs a set of scenarios against the engine (headless) and produces a scored report.
- **Metrics**: Per-scenario pass/fail, tool call accuracy (did it call the right tool with the right args?), response quality signals (hallucination detection via fact-check against provided ground truth), token usage, latency.
- **Regression testing**: Store baseline scores so new agent changes don't degrade behavior. Run on CI via `make test-eval`.

**Why a good fit:** The harness is already structured for automated turns (scheduler turns, goal advances). An eval harness is essentially a special turn source with a known ground truth. It leverages existing orchestration without needing new core infrastructure. Critical for a project that's iterative in nature — you need to know when a refactor breaks agent reasoning.

**Estimated time:** 3–5 days (scenario format + runner + 10 starter scenarios)

---

## 2. Context Engineering & Token Budgeting

**Breakdown:** Implement proactive context management that goes beyond the current compaction threshold. The goal is to reduce token waste and improve answer quality on long sessions.

- **Per-turn context budget**: Track tokens per session in real-time (count tokens from the LLM router's known context size). When the budget is 80% full, trigger a smarter compaction that doesn't just fold oldest → summary, but retains high-signal turns (tool results with unique data, user corrections, fact discoveries).
- **Context summarization strategy**: Instead of a flat rolling summary of oldest turns, use a tiered approach: (a) keep all tool invocations in working memory (they're compact and high-value), (b) summarize free-text exchanges, (c) surface memories instead of raw turns when relevant.
- **Context offloading**: For long fan-out operations or multi-step flows, write intermediate results to the file system or a temporary run-artifact store so the context window doesn't bloat with raw output.

**Why a good fit:** The codebase already has `compaction_threshold_percent` and rolling summaries. This extends the existing mechanism into a budget-aware system with smarter retention policies. The LLM provider abstraction already knows context lengths; wiring that into the context manager is a focused change.

**Estimated time:** 2–4 days

---

## 3. Transient Error Retry with Circuit Breakers

**Breakdown:** Tool calls and LLM calls currently fail loudly on the first error. Add a retry layer for transient failures and a circuit breaker for persistently degraded services.

- **Retry policy**: Configurable per-tool/provider (e.g., 3 retries with exponential backoff for 429 rate limits, network timeouts, or 5xx errors from LLM endpoints). Non-retryable errors (validation failures, auth failures) pass through immediately.
- **Circuit breaker**: If a provider (e.g., OpenRouter, MLX server) fails N times in a window, open the circuit and short-circuit subsequent calls for a cooldown period, falling back to the configured fallback provider. Prevents cascading failures and wasted token burns.
- **Integration point**: The `OrchestratorToolLoop` and `LLMRouter` are the natural places to add this. The existing `BoundedProcessRunner` pattern can be extended with a retry decorator.

**Why a good fit:** The codebase already has `BoundedProcessRunner` and provider fallback. Adding retry logic is a focused pattern that applies uniformly across all tool and LLM calls. This is a production-readiness improvement that requires minimal structural changes.

**Estimated time:** 2–3 days

---

## 4. Structured Tool Call Validation & Self-Correction

**Breakdown:** When the LLM calls a tool with invalid arguments (e.g., missing required fields, wrong types), the system should detect the error and feed a structured error back to the model so it can self-correct — rather than failing the turn outright.

- **Pre-execute validation**: Validate `argumentsJSON` against the tool's `inputSchema` before execution. Return a structured `ToolErrorKind.validationFailure` with field-level error details.
- **Self-correction loop**: Feed the validation error back to the LLM as a tool result (not as a tool error that breaks the turn). The model typically corrects its own arguments on the next attempt.
- **Failure cap**: Limit self-correction attempts per tool call (default 2) to prevent infinite loops with a broken model.

**Why a good fit:** The `ToolInput` already carries `argumentsJSON` and each tool has a JSON schema. Adding pre-execute validation is a thin layer in `ToolBus` or the orchestrator loop. Many open-source agent frameworks now include this pattern because it dramatically reduces tool call failure rates.

**Estimated time:** 1–2 days

---

## 5. Run Artifacts & Structured Output Store

**Breakdown:** Currently, tool results are ephemeral — they live in the session history and get compacted away. Add a persistent run-artifact store so results from important operations (web scrapes, file analyses, email summaries) can be referenced later.

- **Artifact types**: Define artifact categories (webpage, file analysis, email summary, search results, browser state, desktop screenshot) with metadata (tool name, session ID, timestamp, content hash).
- **Artifact retrieval**: Tools or the orchestrator can check if a recent artifact exists for a given target before re-executing an expensive operation (e.g., "was a web search done for this URL in the last hour?").
- **Artifact reference in recall**: Artifacts appear as candidates in `memories.recall` alongside episodic and semantic memory, with a citation pointing back to the original run.

**Why a good fit:** The `RunLogStore` already persists run metadata. Adding an `artifacts` table to `episodes.db` with content BLOB or file reference is additive. This enables deduplication of expensive operations and gives the agent a persistent working space beyond conversation history.

**Estimated time:** 3–4 days

---

## 6. Plugin Marketplace with Signed Updates

**Breakdown:** The roadmap lists a plugin marketplace as planned. Build the infrastructure for discovery, installation, and signed updates without touching the core.

- **Plugin registry**: A remote JSON index (hosted on GitHub or a simple HTTP server) listing available plugins with name, description, version, author, SHA-256 hash, and Python/Swift runtime requirements.
- **Signed installs**: Each plugin release is signed (GPG or ED25519). The engine verifies the signature before enabling. This builds on the existing `PluginDiscoveryService` and `PluginManifest` which already handle SHA-256 tree hash tracking.
- **Update checking**: A periodic background check (configurable via `[plugins]` section) that compares installed plugin hashes against the registry and notifies the user of available updates.
- **Dashboard UI**: A plugins tab in the dashboard showing installed plugins, available updates, and one-click install/enable from the registry.

**Why a good fit:** The plugin discovery and security infrastructure already exists. This extends it with a remote registry, signature verification, and update checking. The plugin layout under `~/.runeweaver/plugins/` is already defined.

**Estimated time:** 5–7 days

---

## 7. Structured Prompts / Template Tools

**Breakdown:** Allow users to define reusable command templates that the agent can fill in. This bridges the gap between free-form chat and deterministic operations.

- **Template format**: A TOML definition with a name, description (for the LLM), template string with `{variables}`, and variable definitions with types and defaults.
- **Built-in templates**: "Summarize my inbox from {since}", "Write a draft email to {recipient} about {topic}", "Compare {file1} and {file2}".
- **User-defined templates**: Stored in config, surfaced via the dashboard's quick-action bar, and passed to the LLM as "shortcut" options in the prompt bar.
- **Execution**: The template is expanded with resolved variables, then sent as a regular prompt. No new tool protocol needed.

**Why a good fit:** This is a configuration + UI change with zero core engine changes. The existing `DashboardPromptBar` component already handles suggestion chips. The `Config` system already supports custom sections. Templates are essentially parameterized prompts.

**Estimated time:** 2–3 days

---

## 8. Run Comparison & Diff View

**Breakdown:** When evaluating the agent (via idea #1's eval harness) or debugging behavior, let users compare two runs side-by-side.

- **Run comparison UI**: Select two runs (by ID or date range) and view them in a side-by-side diff. Show tool call differences, response content differences, token counts, and latency.
- **Session comparison**: For longer sequences (goal plans, fan-out swarms), compare the overall state changes between two points in time.
- **Implementation**: Extend the existing `RunLogViewer` with a comparison mode. The SQLite run logs already have all the data needed.

**Why a good fit:** This is a dashboard-only feature that leverages existing run log data. It pairs naturally with the eval harness to show before/after improvement tracking.

**Estimated time:** 2–3 days

---

## 9. WebSocket-Based Real-Time System Health Widget

**Breakdown:** The dashboard already has a `SystemPulseCard` but it's mostly static. Wire it to real-time WebSocket events for live health monitoring.

- **Live metrics**: Memory engine status, LLM provider health, scheduler next-fire countdown, active fan-out worker count, document index freshness, tool registry status.
- **Alert indicators**: Color-coded status changes (e.g., provider goes unhealthy → yellow/red pulse). Click to see details.
- **Historical health**: A small sparkline chart showing provider availability over the last 24 hours.

**Why a good fit:** The WSHub already broadcasts run events and proactive messages. Adding health event broadcasts is a small extension. The `Health` endpoint already exists. This is primarily a dashboard component change.

**Estimated time:** 1–2 days

---

## 10. Batch Tool Execution & Workflow Chaining

**Breakdown:** Allow users to define multi-step workflows where tool calls execute in sequence with defined inputs/outputs. Think of it as a lightweight DAG for agent operations.

- **Workflow definition**: A JSON structure with nodes (tool calls) and edges (data flow from one tool's output to another's input).
- **Built-in workflows**: "Scan my inbox and summarize" (email.search → summarize → send), "Research and write report" (web.search → web.fetch → files.write).
- **Execution**: The orchestrator executes the workflow step-by-step, pausing at `requiresApproval` nodes. Intermediate results are tracked as run artifacts (idea #5).
- **Dashboard UI**: A workflow editor/launcher in the dashboard where users can trigger predefined workflows.

**Why a good fit:** This extends the existing fan-out and goal systems into a user-defined workflow space. The tool dispatch mechanism already handles sequential execution. Workflow definitions are just serialized in config.

**Estimated time:** 4–6 days

---

## 11. Structured Memory Tagging & Relationship Graph

**Breakdown:** Currently memory is flat — facts are stored with keyword+vector search. Add lightweight tagging and relationship tracking to enable structured recall.

- **Tag system**: Facts can carry user-defined or auto-extracted tags (e.g., `project:acme`, `person:bob`, `topic:finance`). Tags are indexed for fast filtering.
- **Relationships**: Optional `source→target→type` triples (e.g., `Bob → works_for → Acme Corp`). Stored as lightweight edges in `episodes.db`.
- **Query expansion**: When recalling facts about a person, also surface facts about their company and related topics.

**Why a good fit:** This is an additive layer on the existing `EpisodeStore` and `MemoryEngine`. The recall system already merges multiple tiers — tagging/relationships would be a fourth tier. No existing memory behavior changes; it's opt-in enrichment.

**Estimated time:** 3–4 days

---

## 12. Egress Logging & Network Activity Dashboard

**Breakdown:** The harness has sophisticated egress supervision (policy.toml, SSRF guards, credential bindings) but no user-visible log of what network activity the agent has performed.

- **Egress log**: Every supervised outbound call (`api.request`, `web.fetch`, `browser.navigate`, `bash.exec` with URLs) records: destination, method, timestamp, policy verdict, credential used (key name only), response status.
- **Dashboard view**: A "Network" tab showing the egress log with filters (by domain, by tool, by verdict). Outbound calls to unexpected domains are highlighted.
- **Export**: CSV export for compliance audits.

**Why a good fit:** The `OutboundEgressSupervisor` already logs every supervised call. Persisting these to an `egress_log` table in `episodes.db` and adding a dashboard view is a focused extension. It complements the existing policy management UI.

**Estimated time:** 2–3 days

---

## Integration Priority Matrix

| Priority | Idea | Effort | Impact |
|----------|------|--------|--------|
| **P0** | #4 Tool Call Self-Correction | 1-2 days | High — reduces agent failures immediately |
| **P0** | #3 Retry + Circuit Breakers | 2-3 days | High — production reliability |
| **P1** | #1 Eval & Benchmarking Harness | 3-5 days | High — quality measurement |
| **P1** | #2 Context Budgeting | 2-4 days | Medium-High — token efficiency |
| **P1** | #12 Egress Logging Dashboard | 2-3 days | Medium — transparency |
| **P2** | #5 Run Artifacts Store | 3-4 days | Medium — persistent workspace |
| **P2** | #6 Plugin Marketplace | 5-7 days | Medium — ecosystem growth |
| **P2** | #7 Template Tools | 2-3 days | Medium — UX convenience |
| **P3** | #8 Run Comparison | 2-3 days | Medium — debugging |
| **P3** | #9 Live Health Widget | 1-2 days | Low-Medium — polish |
| **P3** | #10 Workflow Chaining | 4-6 days | Medium-High — capability |
| **P3** | #11 Memory Tag Graph | 3-4 days | Medium — recall quality |

---

## Suggested Implementation Order

**Phase A — Reliability Foundation (Week 1):**
- #4 Tool call validation + self-correction (fastest win)
- #3 Retry logic + circuit breakers

**Phase B — Quality & Observability (Week 2):**
- #1 Eval harness (with #8 run comparison as bonus)
- #12 Egress logging dashboard

**Phase C — Capacity Building (Week 3):**
- #2 Context budgeting
- #5 Run artifacts store

**Phase D — Ecosystem & UX (Week 4+):**
- #7 Template tools
- #9 Live health widget
- #6 Plugin marketplace (larger effort)
- #10 Workflow chaining
- #11 Memory tagging

---

## Cross-Cutting Observations

**What the harness already does well:**
- The tool protocol is clean and well-documented (PLUGIN_DEV.md)
- The permission gate with graduated trust is production-grade
- The declarative policy system is unusually thorough (3 formal invariants)
- Actor-based concurrency is well-applied across all subsystems
- The staged file write review loop is a nice UX touch
- Fan-out cancellation and merge is thoughtfully designed
- Test coverage is solid (802 Web tests, structured Swift tests)

**Where the harness is most vulnerable today:**
- LLM/tool failures propagate immediately — no retry or self-correction
- Context window management is reactive (compaction at threshold) rather than proactive
- No way to measure whether agent improvements actually help
- Run results are ephemeral — no persistent working space
- Network activity is supervised but not auditable by the user
- Plugin ecosystem is disconnected — no discovery or update path
