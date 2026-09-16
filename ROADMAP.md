# Rune Weaver — Roadmap

Build map for the harness: what works today and what comes next. Status is either `done-verified` (working in the repo and exercised end to end) or `planned` (not yet built — the Done-criteria line is the acceptance check).

See [ARCHITECTURE.md](ARCHITECTURE.md) for component details and MVP phases, [CONFIG.md](CONFIG.md) for configuration, and [README.md](README.md) for quick start.

| Capability | Phase | Status | Done-criteria |
|------------|-------|--------|---------------|
| Git repo live | 1 Foundation | done-verified | Repo clones with history; remote fetch succeeds. |
| Swift package builds green | 1 Foundation | done-verified | `swift build` and `swift test` pass on a clean checkout. |
| TOML config plus Keychain secrets | 1 Foundation | done-verified | `~/.runeweaver/config.toml` validates; secrets resolve from environment or Keychain, never from TOML. |
| CLI chat over cloud LLM | 1 Foundation | done-verified | `rune-weaver chat` streams replies via OpenRouter; `responses` api_style verified live, `chat-completions` per provider docs and tests. |
| Permission approval prompts in chat | 1 Foundation | done-verified | Chat prompts to allow, allow-with-duration, or deny before any write action runs. |
| Local llama.cpp chat | 1 Foundation | done-verified | `rune-weaver chat` streams live against llama-server; `status` reports reachable. |
| Local MLX provider | 1 Foundation | done-verified | Chat streams live against a local MLX server; `status` reports reachable. |
| Episodic turn persistence | 2 Memory | done-verified | Every chat turn is mirrored to the SQLite episodes store and reloads on restart. |
| Remember capture via remember-that and slash-remember | 2 Memory | done-verified | `remember that <fact>` and `/remember <fact>` store profile and keyword facts without requiring embeddings. |
| Memory search and facts recall | 2 Memory | done-verified | `memory search` and `memory facts` return stored turns and facts by keyword overlap. |
| LLM memory tools — remember_fact plus recall_memories | 2 Memory | done-verified | `remember_fact`/`recall_memories` tool definitions sent every turn; both trusted auto-allowed and audit-logged per the owner memory-write ruling. |
| Automatic recall injection | 2 Memory | done-verified | Bounded keyword recall with nil embeddings injects top hits as source-labeled token-bounded system context; threshold-gated, skipped when nothing scores. |
| Semantic vector embeddings backend | 2 Memory | done-verified | Facts carry local embeddings and `memory search` ranks by vector similarity. |
| Email read — self-hosted IMAP search/read (read-only) | 3 Email | done-verified | `email.search`/`email.read` list, read, and summarize self-hosted IMAP from chat; read-only via `BODY.PEEK`/`readonly=True`, verified TLS, injection-hardened, attachments listed with download deferred. |
| Email read — iCloud IMAP search/read (read-only) | 3 Email | done-verified | `email.search`/`email.read` list, read, and summarize iCloud IMAP from chat; read-only via `BODY.PEEK`/`readonly=True`, verified TLS. |
| Email attachment download | 3 Email | done-verified | `email.attachment` stages attachment bytes under `sandbox/attachments` with a 10 MB cap after an approval prompt; oversize parts skip with a note. |
| Apple Mail native read | 3 Email | planned | List, read, and summarize Apple Mail native messages from chat. |
| Email send with approval | 3 Email | done-verified | Compose and send email only after an explicit approval prompt; every send is logged. |
| Playwright browser tool plus multi-step email-to-web flows | 4 Browser plus Multi-step | planned | Navigate, read, and fill pages in a sandboxed context; an email link to web confirm runs end to end. |
| HomeKit control | 5 Home plus Comms | planned | List and control HomeKit accessories and scenes from chat with approval. |
| Home Assistant control | 5 Home plus Comms | planned | Query and control Home Assistant entities via URL plus token from chat with approval. |
| Discord read | 5 Home plus Comms | planned | Read and summarize Discord channel messages and mentions from chat. |
| GitHub integration | 5 Home plus Comms | planned | List issues and PRs and summarize repos via API with a token from the Keychain. |
| Apple Messages read | 5 Home plus Comms | planned | Read and summarize recent Apple Messages threads from chat. |
| Calendar integration | 5 Home plus Comms | planned | List upcoming events and answer availability questions from chat. |
| Whisper STT plus system TTS plus push-to-talk | 6 Voice plus Polish | planned | Push-to-talk transcribes via local Whisper and speaks replies via system TTS. |
| macOS menu bar app | 6 Voice plus Polish | done-verified | Menu bar chat window with approval notifications runs on macOS. |
| Plugin marketplace | 7 Self-Improvement | planned | Install, update, and remove plugins from a registry without touching the core. |
| iOS app | 8 Clients plus Runtime | planned | SwiftUI iOS client chats over VPN with push-to-talk and approval prompts. |
| Local web dashboard | 8 Clients plus Runtime | done-verified | Dashboard chats, browses memory, and manages approvals/scheduler in a browser via the engine-served `Web/dist` bundle (`DashboardBundle`, `Web/src/*`, vitest + `DashboardBundleTests`). |
| launchd daemon | 8 Clients plus Runtime | planned | Core engine runs as a launchd service and restarts cleanly on reboot. |
| Scheduler cron plus event triggers | 8 Clients plus Runtime | done-verified | Cron and email-arrival jobs fire headless under stable sessions with run logging and notifications (`SchedulerEngine`, `SchedulerCommand run`, `SchedulerTests`). |
| Engine API — Vapor localhost service | 8 Clients plus Runtime | done-verified | Vapor API serves chat, tools, memory, approvals, scheduler, and runs on loopback with JSON errors (`RuneWeaverServer`, `ServerTests`). |
| Dashboard — static bundle served by engine | 8 Clients plus Runtime | done-verified | Static `Web/dist` bundle served by the engine on the same loopback origin with stub reporting when unbuilt (`DashboardBundle`, `DashboardBundleTests`). |
| Approvals inbox — dashboard plus CLI | 8 Clients plus Runtime | done-verified | Pending `requiresApproval` actions list in the dashboard inbox and `GET /approvals`; approve-with-duration or deny flows through the permission gate (`ApprovalQueue`, `ApprovalsInbox`, `ApprovalQueueTests`). |
| Scheduler engine — persistent cron plus event triggers | 8 Clients plus Runtime | done-verified | `config.toml [[scheduler.jobs]]` is the source of truth bridged into the REST registry; fires run headless and log every outcome (`SchedulerStore` + `SchedulerEngine`, `SchedulerTests` + `SchedulerStoreTests`). |
| Scheduler UI — dashboard management | 8 Clients plus Runtime | done-verified | Dashboard lists, creates, enables, disables, and manually runs schedules against the engine API (`SchedulerManager`, scheduler job routes, `ServerTests`). |
