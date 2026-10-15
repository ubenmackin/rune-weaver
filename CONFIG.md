# Configuration Reference

All non-sensitive settings live in `~/.runeweaver/config.toml`. The DMG app and the CLI use the same file. If you run the app, skip the copy step below and fill in the Settings page in the dashboard. The page writes this file for you, so prefer the page over hand edits.

Copy the example file to get started from source:

```bash
mkdir -p ~/.runeweaver
cp Config/config.toml.example ~/.runeweaver/config.toml
```

If the file is absent, the engine uses built-in defaults (`RuneWeaverConfig.default`). If it exists, it is parsed and validated on load — invalid files throw a descriptive `ConfigError` (file, line, or dotted field path) instead of silently falling back. The file is read once at engine startup by `CLIConfigLoader.loadConfig(path:)`; there is no file-watching hot reload, so hand edits take effect on the next engine start.

Secrets (API keys, passwords, tokens) are **never** stored in this file. See [Secrets Management](#secrets-management) below.

Network egress policies, domain allowlists, and loopback/SSRF exemptions are managed separately in `~/.runeweaver/policy.toml`. See [Declarative Security Policy](#declarative-security-policy) below.

## Full Option Reference

### `[engine]`

Identity, logging, compaction, and execution loop controls.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `name` | string | `"Rune Weaver"` | Engine display name shown in clients. Must not be empty. |
| `log_level` | string | `"info"` | One of `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical` (case-insensitive). |
| `compaction_threshold_percent` | integer | `80` | Context compaction threshold in percent (`10`–`100`). Oldest turns fold into a rolling summary past this budget. |
| `max_tool_iterations` | integer | `10` | Maximum consecutive tool execution rounds per interactive chat turn before continuation approval is requested (1-100). Chats only; scheduled runs use [scheduler] max_tool_iterations (default 25) and goal runs use [goals] max_tool_iterations (default 35). |

### `[server]`

HTTP API bind endpoint and network exposure policy.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `hostname` | string | `"127.0.0.1"` | Interface the engine binds. Non-loopback addresses (`0.0.0.0` or LAN IP) require an authenticated token; unauthenticated non-loopback binds fail closed at boot. |
| `port` | integer | `8082` | TCP port for the engine service. Default 8082 avoids MLX (8080) and llama.cpp (8081). |
| `allowed_hosts` | array of strings | `[]` | Extra exact hostnames accepted by the Host gate (e.g. `["my-mac.tail123.ts.net"]`). Max 20 entries, max 253 characters each. No wildcards, CIDR, or schemes. |

```toml
[server]
hostname = "127.0.0.1"
port = 8082
# allowed_hosts = ["mac-studio.tailscale.net"]
```

### `[auth]`

Single-owner bearer token configuration. Required when exposing the engine on non-loopback addresses. The token value itself **never** lives in this file.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `token_env` | string \| unset | `"RUNEWEAVER_AUTH_TOKEN"` | Environment variable holding the bearer token. |
| `token_file` | string \| unset | `"~/.runeweaver/auth_token"` | Path to a `0600` file holding the bearer token. |

Resolution hierarchy:
1. Environment variable named by `token_env` (Docker/headless).
2. macOS Keychain item `(service: com.runeweaver.secrets, account: RUNEWEAVER_AUTH_TOKEN)`.
3. Token file named by `token_file`.

Generate or rotate tokens via CLI (`rune-weaver auth token generate` / `rune-weaver auth token rotate`) or the Settings page in the dashboard.

### `[llm]`

Top-level provider routing.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `default_provider` | string | `"mlx"` | Key under `[llm.providers.*]` to use first. Required, must not be empty. |
| `fallback_provider` | string \| unset | `"openrouter"` | Provider to try when the default is unhealthy. Omit or leave unset for no fallback. Must not be empty when set. |

### `[llm.providers.<name>]`

Each provider entry supports the same keys. Only set what that backend needs.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `true` | Whether the router may select this provider. |
| `model` | string \| unset | unset | Model identifier sent with requests (e.g. `"gemma-4-9b"`). Local servers only; must not be empty when set. |
| `server_url` | string \| unset | unset | Server URL (MLX / llama.cpp / vLLM / OpenAI-compatible endpoint). Must be an absolute URL when set. |
| `api_key_env` | string \| unset | unset | Environment variable (and Keychain key) holding the API key. Resolved via `SecretsManager`; never put the key itself in TOML. |
| `provider_type` | string \| unset | unset | Backend type for generic local entries (e.g. `"llamacpp"`). |
| `api_style` | string | `"chat-completions"` | Request style: `"chat-completions"` (`POST /chat/completions`, default) or `"responses"` (`POST /responses`). Use `"responses"` for the `muse-spark` family. |
| `context_length` | integer \| unset | `unset (backend default)` | Context window in tokens override (e.g. `1000000` for 1M endpoints). Omit to use the backend default (MLX `8192`, llama.cpp `4096`, OpenAI-compatible `128000`). |
| `supports_vision` | boolean \| unset | unset | Whether the model accepts vision input (screenshots/images). Nil uses backend defaults (`true` for cloud endpoints, `false` for local servers). |
| `slot_count` | integer \| unset | `unset (server auto-assign)` | llama.cpp-only sticky `id_slot` pool size. Must be positive when set. Match `llama-server --parallel` to opt into prefix reuse; omit so the server auto-assigns. |
| `cache_prompt` | boolean \| unset | `unset (enabled)` | llama.cpp-only prefix-cache hint sent as `cache_prompt`. Omit to keep the always-on default; set `false` to disable. |

Shipped defaults (`RuneWeaverConfig.default`):

```toml
[llm.providers.mlx]
enabled = true
model = "gemma-4-9b"
server_url = "http://localhost:8080"
# context_length = 8192

[llm.providers.openrouter]
enabled = true
api_key_env = "OPENROUTER_API_KEY"
server_url = "https://openrouter.ai/api/v1"
# context_length = 128000

[llm.providers.local]
enabled = false
provider_type = "llamacpp"
server_url = "http://localhost:8081"
# context_length = 4096
```

### `[memory]`

Episodic memory, semantic memory vectors, and recall fan-out budgets.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `vector_db_path` | string | `"~/.runeweaver/memory/vectors"` | JSON store path for semantic memory (LanceDB-compatible shape) holding keyword-only rows plus optional embedding vectors. |
| `episodes_db_path` | string | `"~/.runeweaver/memory/episodes.db"` | SQLite database path for episodic memory, conversation history, run logs, and scheduled jobs. |
| `embedding_model` | string | `"all-MiniLM-L6-v2"` | Retained for forward compatibility; reserved for future model selection. |
| `embedding_backend` | string | `"local"` | Vector backend: `"local"` (on-device EmbeddingGemma 2 on Metal via llama.cpp), `"provider"` (chat model `/v1/embeddings`), or `"none"` (keyword-only). |
| `recall_per_tier_limit` | integer | `5` | Maximum hits fetched per tier before merging (`1`–`50`). |
| `recall_auto_limit` | integer | `5` | Maximum hits injected as system context per auto turn (`1`–`50`). |
| `recall_threshold` | double | `0.1` | Minimum calibrated score for an injected recall hit (`0.0`–`1.0`). |
| `recall_max_chars` | integer | `8000` | Maximum total characters for the injected recall block, header included (`500`–`32000`). |
| `recall_per_hit_chars` | integer | `2000` | Maximum characters kept per individual hit before boundary truncation (`100`–`8000`). |
| `recall_doc_pool_multiplier` | integer | `4` | Widening factor for the document candidate pool: the pool widens to `page * multiplier`, the vector leg scans `min(max(pool * 10, 500), maxPerTierResults)` chunks from it, and the keyword leg reads at the same width. Inert at the default page size — it only moves the vector leg once `pool * 10` clears the 500-row floor (`1`–`8`). |
| `recall_episodic_weight` | double | `0.25` | Weight mapping episodic rank scores onto the shared recall scale (`0.0`–`1.0`). |

```toml
[memory]
vector_db_path = "~/.runeweaver/memory/vectors"
episodes_db_path = "~/.runeweaver/memory/episodes.db"
embedding_backend = "local"
# recall_auto_limit = 5
# recall_threshold = 0.1
# recall_max_chars = 8000
```

### `[voice]`

Speech-to-text and text-to-speech providers.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `stt_provider` | string | `"whisper"` | Speech-to-text provider. |
| `whisper_model` | string | `"base"` | Whisper model size (e.g. `tiny`, `base`, `small`). |
| `tts_provider` | string | `"system"` | Text-to-speech provider (`"system"` uses macOS `say`). |

### `[containers]`

Unified container policy for sandboxed execution and detonation work.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `memory_mb` | integer | `512` | Memory budget in megabytes per container (`256`–`8192`). |
| `max_concurrent` | integer | `5` | Maximum containers running at once (`1`–`32`). |
| `ttl_minutes` | integer | `60` | Idle lifetime in minutes before reclamation (`5`–`1440`). |

Container images are pinned in code and carry no config key: strict per-turn and machine-scoped workspace containers run `debian:stable-slim`; detonation containers run `alpine:3.22`. Legacy `[sandbox]` keys (`container_base_image`, `archive_session_ttl_minutes`, `max_concurrent_machines`) are ignored on load with a logged note and shed on resave.

```toml
[containers]
memory_mb = 512
max_concurrent = 5
ttl_minutes = 60
```

### `[files]`

Sensitive-path guard and review postures for the `files.*` suite. Changes apply live without restart.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `deny_patterns` | array of strings | `[...]` | Glob-like patterns denied by the file access guard (e.g. `[".env*", ".ssh/*", "config.toml", ".runeweaver/policy.toml"]`). Core engine paths are permanently protected. |
| `allow_roots` | array of strings | `["~"]` | Allowed root directories for live file access (`~` expands to home). Outside-root paths escalate to approval. |
| `require_approval_on_deny` | bool | `true` | Whether deny hits escalate to the approvals inbox (`true`) or fail closed (`false`). |
| `write_mode` | string | `"model"` | Forced write posture for `files.write`: `"model"` (agent chooses per call; omitted defaults to staged review), `"staged"` (forces every write into Staged Changes), `"live"` (writes immediately with `.rune_backup_` rollback copy). |

```toml
[files]
deny_patterns = [".env*", ".netrc", "secrets.json", "config.toml", "*.pem", "*.key", "*keychain*", ".ssh/*", ".aws/*", ".runeweaver/memory/*", ".runeweaver/policy.toml", ".runeweaver/auth_token"]
allow_roots = ["~"]
require_approval_on_deny = true
write_mode = "model"
```

### `[index]`

Local background indexer for files, mail, and Apple Messages. Off by default so fresh installs remain quiet until opted in.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `false` | Master toggle for the local background indexer. |
| `files` | bool | `true` | Index local document files when indexer is enabled. |
| `mail` | bool | `false` | Index configured `[[email.accounts]]` mailboxes over read-only IMAP `BODY.PEEK`. |
| `messages` | bool | `false` | Index Apple Messages from `~/Library/Messages/chat.db` (requires Full Disk Access). |
| `roots` | array of strings | `["~"]` | File walk root directories (`~` expands to home). |
| `exclude` | array of strings | `[...]` | Glob patterns skipped during file walk (e.g. `.build`, `*.log`, `node_modules`, `*.tmp`, build/cache directories). |
| `max_file_mb` | integer | `20` | Maximum file size in MB the indexer will read (`1`–`10240`). |
| `mail_vector_window` | string | `"2y"` | How far back mail is vectorized: `"30d"`, `"6m"`, `"1y"`, `"2y"`, or `"all"`. Older mail remains keyword-searchable. |
| `icloud_evicted` | string | `"skip"` | Policy for iCloud files whose bytes are evicted: `"skip"` (leave out) or `"download"` (pull down before indexing). |
| `nightly_budget` | integer | `0` | Maximum items processed per nightly run; `0` means unlimited (`0`–`100000`). |
| `max_vector_chunks_per_document` | integer | `128` | Maximum chunks per document that carry vectors (`1`–`4096`). Remaining chunks stay keyword-searchable. |
| `mailbox_deny` | array of strings | `["Trash", "Junk", "Spam", "Deleted*"]` | Mailboxes skipped without dialing. |
| `effort` | string | `"balanced"` | CPU effort preset: `"light"` (1 worker), `"balanced"` (half cores up to 4), `"performance"` (all but one core), or `"custom"`. |
| `workers` | integer | `0` | Explicit worker count when `effort = "custom"` (`1`–`64`). `0` derives from preset. |
| `thermal_backoff` | bool | `true` | Back off worker threads when macOS reports thermal pressure. |
| `pause_on_battery` | bool | `false` | Pause indexing runs while on battery power; resume on AC. |
| `db_path` | string | `"~/.runeweaver/index.db"` | SQLite database path for the document index. |

```toml
[index]
enabled = true
files = true
mail = false
messages = false
roots = ["~"]
max_file_mb = 20
effort = "balanced"
thermal_backoff = true
```

### `[browser]`

Local web search via self-hosted SearXNG and Playwright browser automation.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `searxng_url` | string | `"http://127.0.0.1:8888"` | Base URL of SearXNG (`/search` is appended). Must be an absolute URL. |
| `search_timeout_seconds` | integer | `10` | Per-search HTTP timeout in seconds (`1`–`120`). |
| `max_results` | integer | `10` | Maximum results per `web.search` call (`1`–`50`). |
| `timeout_seconds` | integer | `30` | Per-action timeout in seconds for Playwright browser automation (`5`–`300`). |
| `fetch_timeout_seconds` | integer | `15` | Per-request HTTP timeout in seconds for `web.fetch` and `api.request` (`1`–`120`). |

```toml
[browser]
searxng_url = "http://127.0.0.1:8888"
search_timeout_seconds = 10
max_results = 10
timeout_seconds = 30
fetch_timeout_seconds = 15
```

### `[desktop]`

Perception and automation capture knobs for `desktop.screenshot` and `desktop.action`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `max_image_dimension` | integer | `1280` | Longest edge of downscaled screenshots in pixels (`256`–`3840`). Bounds token cost. |
| `jpeg_quality` | double | `0.75` | JPEG compression quality for downscaled screenshots (`0.1`–`1.0`). |
| `blocked_apps` | array of strings | `[...]` | Application names where `desktop.action` refuses to dispatch input (Terminal, Keychain Access, System Settings, 1Password, Bitwarden, etc.). |

> [!IMPORTANT]
> The `[desktop]` section carries only capture knobs. Desktop tools ship disabled and are enabled exclusively via the persisted tool toggle in Settings → Tools or the tool-state API.

```toml
[desktop]
max_image_dimension = 1280
jpeg_quality = 0.75
blocked_apps = ["Terminal", "iTerm2", "Keychain Access", "System Settings", "1Password", "Bitwarden"]
```

### `[bash]` & `[[bash.rules]]`

Granular shell execution policy for `bash.exec`, confined by macOS Seatbelt (`sandbox-exec`, deny-default).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `true` | Whether the `bash.exec` tool is enabled. |
| `default_action` | string | `"ask"` | Default action if no rule matches: `"allow"`, `"ask"`, or `"deny"`. |
| `timeout_seconds` | integer | `30` | Default execution timeout in seconds (`1`–`3600`). |
| `allow_network` | bool | `false` | Whether commands may access network interfaces from inside the Seatbelt sandbox. |

`[[bash.rules]]`: Rules evaluate top-to-bottom with **last-match-wins** semantics. Put catch-alls first and specific overrides after.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `pattern` | string | (required) | Command prefix or glob pattern to match (e.g. `"*"`, `"git status"`, `"swift test *"`). |
| `action` | string | (required) | Permission action: `"allow"`, `"ask"`, or `"deny"`. |

```toml
[bash]
enabled = true
default_action = "ask"
timeout_seconds = 30
allow_network = false

[[bash.rules]]
pattern = "*"
action = "ask"

[[bash.rules]]
pattern = "git status"
action = "allow"
```

### `[email]` — `[[email.accounts]]`

Repeat `[[email.accounts]]` per account. Passwords live in the Keychain (`EMAIL_<ACCOUNT>_PASSWORD`), never in TOML.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `name` | string | (required) | Account nickname (e.g. `"icloud"`). |
| `type` | string | `"imap"` | Account protocol type. |
| `host` | string | (required) | IMAP server hostname. |
| `port` | integer | `993` | IMAP TLS port. |
| `username` | string | (required) | Login username. |
| `smtp_host` | string \| unset | unset | SMTP submission host override (nil derives from IMAP host). |
| `smtp_port` | integer \| unset | unset | SMTP port override (typically `587` STARTTLS or `465` SSL). |
| `smtp_security` | string | `"auto"` | Transport security: `"ssl"`, `"starttls"`, or `"auto"`. |

```toml
[[email.accounts]]
name = "icloud"
type = "imap"
host = "imap.mail.me.com"
port = 993
username = "user@icloud.com"
smtp_host = "smtp.mail.me.com"
smtp_port = 587
smtp_security = "auto"
```

### `[home]` — `[[home.homekit]]` / `[[home.home_assistant]]`

`[[home.homekit]]`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `true` | Whether HomeKit control is enabled. |

`[[home.home_assistant]]`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `true` | Whether Home Assistant control is enabled. |
| `url` | string \| unset | unset | Home Assistant base URL (e.g. `http://homeassistant.local:8123`). |
| `token_env` | string \| unset | unset | Env var (and Keychain key) holding the access token. |

### `[media]` — `[media.sonarr]` / `[media.radarr]`

Self-hosted media automation managers used by `media.arr` and `media.arr.read`. API keys resolve via `SecretsManager` (`SONARR_API_KEY`, `RADARR_API_KEY`).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `timeout_seconds` | integer | `15` | Per-request HTTP timeout in seconds for media automation calls (`5`–`120`). |

`[media.sonarr]` / `[media.radarr]`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `true` | Whether the integration is enabled. |
| `url` | string \| unset | unset | Base service URL (e.g. `http://localhost:8989`). Must be set to activate. |
| `api_key_env` | string \| unset | unset | Env var / Keychain key holding the service API key. |
| `default_quality_profile` | string \| unset | unset | Optional default quality profile name (e.g. `"HD-1080p"`). Auto-detected when unset. |
| `default_root_folder` | string \| unset | unset | Optional root media path (e.g. `"/data/media/tv"`). Auto-detected when unset. |

```toml
[media]
timeout_seconds = 15

[media.sonarr]
enabled = true
url = "http://localhost:8989"
api_key_env = "SONARR_API_KEY"

[media.radarr]
enabled = true
url = "http://localhost:7878"
api_key_env = "RADARR_API_KEY"
```

### `[scheduler]` — `[[scheduler.jobs]]`

Persistent cron and email-arrival scheduled jobs. Config `[[scheduler.jobs]]` entries act as bootstrap seeds on initial startup when zero jobs exist in SQLite.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `name` | string | (required) | Job name (e.g. `"morning digest"`). |
| `prompt` | string | (required) | Prompt executed when the job fires. |
| `enabled` | bool | `true` | Whether the job is active. |
| `schedule` | string \| unset | unset | Cron expression (`"0 8 * * *"`) or `@hourly` / `@daily` / `@weekly`. |
| `poll_account` | string \| unset | unset | Account name from `[[email.accounts]]` to poll for unseen arrivals. |
| `poll_query` | string \| unset | `""` | Search query for new arrivals (empty matches latest). |
| `poll_mailbox` | string \| unset | unset | Mailbox to search (omitted means all). |
| `poll_interval_seconds` | integer \| unset | `300` | Seconds between poll checks. |
| `poll_limit` | integer \| unset | `10` | Maximum hits per poll (`1`–`50`). |
| `max_tool_iterations` | integer | `25` | Default consecutive tool rounds per scheduled run before the limit policy triggers (1-100). Per-job `max_tool_iterations` overrides this default. Default policy synthesizes plus budget_exceeded; a job with `on_tool_limit = "park"` parks instead. |
| `jobs.max_tool_iterations` | integer \| unset | unset (section default) | Per-job consecutive tool rounds override for this job (1-100). Omit to inherit `[scheduler] max_tool_iterations` (default 25). |
| `jobs.on_tool_limit` | string \| unset | unset (inherit, synthesizes) | Per-job limit policy when the budget is reached: `"fail"` synthesizes plus `budget_exceeded`, `"park"` parks for approval instead. Omit (or `""`/nil) to inherit — unset behaves like `"fail"` (synthesize). |

### `[plugins]`

External rune plugin discovery and community marketplace.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `plugins_dir` | string | `"~/.runeweaver/plugins"` | Directory scanned for external rune packages. |
| `marketplace_index_url` | string | `"https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/index.json"` | Remote marketplace catalog index URL. |
| `auto_rescan` | bool | `true` | Automatically scan plugins directory on startup. |

### `[goals]`

Steady pursuit of long-horizon autonomous goals. Off by default so stock installs do not consume background model turns.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `false` | Master toggle for autonomous goal advancement and triggers. |
| `step_interval_minutes` | integer | `1440` | Default cadence hint stored on new goals (`5`–`20160` minutes, default 24h). |
| `max_active_goals` | integer | `10` | Maximum goals in active state at once (`1`–`50`). |
| `max_steps_per_goal` | integer | `12` | Maximum steps in one decomposed goal plan (`1`–`24`). |
| `plan_timeout_seconds` | integer | `0` | Timeout in seconds for the planning model call; `0` means unlimited, otherwise settle to unplanned with empty steps (`0`–`86400`). |
| `max_triggers_per_goal` | integer | `8` | Maximum event triggers armed on one goal (`0`–`32`). |
| `max_tool_iterations` | integer | `35` | Maximum tool loop iterations per goal turn before force-synthesis plus budget_exceeded (1-100). Always synthesizes; never parks. |

```toml
[goals]
enabled = false
step_interval_minutes = 1440
max_active_goals = 10
max_steps_per_goal = 12
plan_timeout_seconds = 0
max_triggers_per_goal = 8
```

### `[proactive]`

Interruption policy filtering macOS notifications and dashboard interruption frames for background turns. Run history and approvals always record regardless of mode.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `mode` | string | `"all"` | Surfacing mode: `"all"` (all outcomes), `"milestones"` (milestones + errors + parked turns), `"guarded"` (milestones + judge model call on routine successes), `"off"` (no interruptions). |
| `judge_timeout_seconds` | integer | `15` | Timeout in seconds for guarded judge evaluation (`1`–`120`). |

```toml
[proactive]
mode = "all"
judge_timeout_seconds = 15
```

### `[ideas]`

Proactive Wayfinder suggestions reviewing goal outcomes and memory facts to brainstorm next steps.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `false` | Whether proactive idea generation runs during nightly ticks and on goal completion. |
| `max_per_cycle` | integer | `3` | Maximum candidate ideas persisted per generation cycle (`1`–`10`). |
| `timeout_seconds` | integer | `20` | Review model timeout in seconds before returning empty (`1`–`120`). |

```toml
[ideas]
enabled = false
max_per_cycle = 3
timeout_seconds = 20
```

### `[fanout]`

Tuning for parallel worker swarms via `fanout.run`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `max_workers` | integer | `2` | Maximum concurrent workers running at once (`1`–`8`). |
| `worker_timeout_seconds` | integer | `0` | Timeout per worker turn in seconds; `0` means unlimited (`0`–`86400`). |
| `full_tools` | bool | `false` | When `false`, workers receive read-only tools only. When `true`, widens workers to full tool registry. |

> [!IMPORTANT]
> Enablement is gated solely by the `fanout.run` tool toggle in Settings → Tools. `[fanout]` carries swarm tuning only.

```toml
[fanout]
max_workers = 2
worker_timeout_seconds = 0
full_tools = false
```

### `[security]`

Harness-level content protection defaults. Both default to `true` (fail-hardened).

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `untrusted_labeling` | bool | `true` | Wraps network-derived tool output in data-only delimiters so models do not mistake content for instructions. |
| `email_credential_filter` | bool | `true` | Redacts one-time passwords, login tokens, and magic links from agent-visible mail context while leaving human mailboxes untouched. |

```toml
[security]
untrusted_labeling = true
email_credential_filter = true
```

---

## Declarative Security Policy

Network egress permissions and SSRF defenses are governed by `~/.runeweaver/policy.toml`, which operates with a **deny-by-default** stance managed via the Policy pane in dashboard Settings or `rune-weaver policy`:

- **`[network]`**: Egress allowlist rules and `local_exemptions` for internal homelab domains/hosts (e.g. `homeassistant.local`, `192.168.1.50`).
- **SSRF Guard**: Loopback and cloud metadata endpoints (`169.254.169.254`, etc.) are blocked by default. SearXNG and local LLM endpoints configured in `config.toml` receive automatic targeted exemptions.
- **Atomic updates & FIFO locking**: `PolicyStore` ensures that policy changes are verified against invariant rules and saved atomically.

---

## Secrets Management

Lookup order in `SecretsManager.retrieve(key:)`:

1. **Environment variable** `key` (Docker/vault injection) — takes precedence.
2. **macOS Keychain** item `(service: com.runeweaver.secrets, account: key)`.

Writes always go to the Keychain. Secrets are never logged, never embedded in errors, and never written to `config.toml`.

Config keys that reference secrets (`api_key_env`, `token_env`, email passwords) only **name** the variable — `SecretsManager.resolve(_:)` fetches the value at execution time, so the LLM prompt never contains credentials.

```bash
# Environment (dev/Docker)
export OPENROUTER_API_KEY="sk-or-..."
export HA_TOKEN="your-home-assistant-token"
export SONARR_API_KEY="your-sonarr-api-key"
export RADARR_API_KEY="your-radarr-api-key"

# Keychain (recommended for macOS)
# Stored via the app or CLI under service "com.runeweaver.secrets"
```

---

## Common Configurations

**Local-first with cloud fallback (recommended):**

```toml
[engine]
name = "Rune Weaver"
log_level = "info"

[server]
hostname = "127.0.0.1"
port = 8082

[llm]
default_provider = "mlx"
fallback_provider = "openrouter"

[llm.providers.mlx]
enabled = true
model = "gemma-4-9b"
server_url = "http://localhost:8080"

[llm.providers.openrouter]
enabled = true
api_key_env = "OPENROUTER_API_KEY"
server_url = "https://openrouter.ai/api/v1"

[files]
write_mode = "staged"

[index]
enabled = true
files = true
mail = false
messages = false
roots = ["~"]
```

**Tailscale / Remote headless node:**

```toml
[server]
hostname = "0.0.0.0"
port = 8082
allowed_hosts = ["mac-studio.tailnet-xyz.ts.net"]

[auth]
token_env = "RUNEWEAVER_AUTH_TOKEN"
token_file = "~/.runeweaver/auth_token"
```

**Privacy-hardened local only (no cloud, no network bash):**

```toml
[llm]
default_provider = "mlx"

[bash]
enabled = true
default_action = "ask"
allow_network = false

[security]
untrusted_labeling = true
email_credential_filter = true
```
