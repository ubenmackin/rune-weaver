# Configuration Reference

All non-sensitive settings live in `~/.runeweaver/config.toml`. The DMG app and the CLI use the same file. If you run the app, skip the copy step below and fill in the Settings page in the dashboard. The page writes this file for you, so prefer the page over hand edits.

Copy the example file to get started from source:

```bash
mkdir -p ~/.runeweaver
cp Config/config.toml.example ~/.runeweaver/config.toml
```

If the file is absent, the engine uses built-in defaults (`RuneWeaverConfig.default`). If it exists, it is parsed and validated on load — invalid files throw a descriptive `ConfigError` (file, line, or dotted field path) instead of silently falling back. `ConfigLoader` can hot-reload the file: invalid reloads keep the last good snapshot and report the error via `onError`.

Secrets (API keys, passwords, tokens) are **never** stored in this file. See [Secrets Management](#secrets-management) below.

## Full Option Reference

### `[engine]`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `name` | string | `"Rune Weaver"` | Engine display name shown in clients. Must not be empty. |
| `log_level` | string | `"info"` | One of `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical` (case-insensitive). |

### `[llm]`

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
| `api_style` | string | `"chat-completions"` | Request style: `"chat-completions"` (`POST /chat/completions`, default) or `"responses"` (`POST /responses`). Use `"responses"` for the `muse-spark` family; use `"chat-completions"` for `glm`, `kimi`, `deepseek`, `mimo`, `hy`, and `longcat`. Models requiring Anthropic-style messages input are unsupported. |
| `context_length` | integer \| unset | `unset (backend default)` | Context window, per-provider override (e.g. `1000000` for 1M endpoints), must be positive. Omit to use the backend default (MLX `8192`, llama.cpp `4096`, OpenAI-compatible `128000`). |

Shipped defaults (`RuneWeaverConfig.default`):

```toml
[llm.providers.mlx]
enabled = true
model = "gemma-4-9b"
server_url = "http://localhost:8080"
# context_length = 8192  # optional override; omit for the backend default (MLX 8192, llama.cpp 4096, OpenAI-compatible 128000)

[llm.providers.openrouter]
enabled = true
api_key_env = "OPENROUTER_API_KEY"
server_url = "https://openrouter.ai/api/v1"
# context_length = 1000000  # e.g. 1000000 for 1M-context endpoints

[llm.providers.local]
enabled = false
provider_type = "llamacpp"
server_url = "http://localhost:8081"
```

`api_style` selects the OpenAI-compatible request shape per provider. It defaults to `"chat-completions"`. Set `api_style = "responses"` for the `muse-spark` family; keep `"chat-completions"` for `glm`, `kimi`, `deepseek`, `mimo`, `hy`, and `longcat`. Models that require an Anthropic-messages request shape are unsupported.

```toml
[llm.providers.openrouter]
enabled = true
api_key_env = "OPENROUTER_API_KEY"
server_url = "https://openrouter.ai/api/v1"
api_style = "responses"  # muse-spark family; omit or use "chat-completions" for glm, kimi, deepseek, mimo, hy, longcat
```

### `[memory]`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `vector_db_path` | string | `"~/.runeweaver/memory/vectors"` | JSON store path for semantic memory (LanceDB-compatible shape) holding keyword-only rows plus optional embedding vectors written through `embedding_backend`. Must not be empty. |
| `episodes_db_path` | string | `"~/.runeweaver/memory/episodes.db"` | SQLite path for episodic memory (conversation history). Must not be empty. |
| `embedding_model` | string | `"all-MiniLM-L6-v2"` | Retained for forward compatibility but currently unused; reserved for future small/embedding-model support. `apple` uses the fixed on-device model with no model config, `provider` reuses the active chat model via `/v1/embeddings`, and `none` stays keyword-only. Must not be empty. |
| `embedding_backend` | string | `"apple"` | Embedding backend: `"apple"` (on-device), `"provider"` (active chat model embeddings), or `"none"` (keyword-only). Must be one of the three. |

Semantic memory selects its vector backend via `embedding_backend` (default `"apple"`). `apple` keeps vectors on-device with the fixed on-device model and no model config, `provider` reuses the active chat model for embeddings via `/v1/embeddings`, and `none` stays keyword-only with no vectors. `embedding_model` is retained but unused today. Switching chat models under `provider` may require a vector reset due to width pinning. `remember` in chat (`remember <fact>`, `remember that <fact>`, `/remember <fact>`) stores facts in structured stores — profile facts plus keyword-scored vector rows — so `memory facts` lists them in every mode.

### `[voice]`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `stt_provider` | string | `"whisper"` | Speech-to-text provider. Must not be empty. |
| `whisper_model` | string | `"base"` | Whisper model size (e.g. `tiny`, `base`, `small`). Must not be empty. |
| `tts_provider` | string | `"system"` | Text-to-speech provider (`system` = macOS `say` command). Must not be empty. |

### `[sandbox]`

Tier-3 detonation only: there is no host staging. Document writes use Seatbelt-confined temp with an atomic move on approval, and archives detonate in ephemeral microVMs with manifest-only returns.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `container_base_image` | string | `"alpine:latest"` | OCI base image for detonation microVMs. Must not be empty. |
| `archive_session_ttl_minutes` | integer | `10` | Crash-orphan reclamation TTL for ephemeral detonation machines. Must be 1–1440. |
| `max_concurrent_machines` | integer | `3` | Maximum simultaneous detonation machines, enforced before spawn. Must be positive. |

Archive detonation always uses the Apple Container CLI (`container`); there is no `container_runtime` key. Older files carrying the key load with the hardcoded default.

Legacy staging keys (`staging_path`, `retention_days`, `max_total_bytes`, `cleanup_interval_seconds`) in older files are ignored with no crash and no migration; manually clean old dev-only staging directories.

### `[browser]`

Local web search via self-hosted SearXNG plus bounded page fetch. Search runs against the local SearXNG JSON API so queries never leave operator infrastructure; fetch follows server redirects manually with a per-hop allowlist. The Settings web page is the easiest way to edit these values.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `searxng_url` | string | `"http://127.0.0.1:8888"` | Base URL of the local SearXNG service (`/search` is appended). Must be an absolute http(s) URL. |
| `search_timeout_seconds` | integer | `10` | Per-search HTTP timeout in seconds. Must be 1–120. |
| `max_results` | integer | `10` | Maximum results per `web.search` call, bounding context fan-out. Must be 1–50. |

```toml
[browser]
searxng_url = "http://127.0.0.1:8888"
search_timeout_seconds = 10
max_results = 10
```

The engine ensures SearXNG on `serve` boot and on first `web.search`: it probes the base URL, otherwise starts an existing `runeweaver-searxng` container or runs one from tracked `searxng/searxng:latest` (`:latest` by design so fresh runs follow upstream without a version bump; pin via `SEARXNG_IMAGE=searxng/searxng:<tag>` when reproducibility matters; keep in sync with `SearXNGEnsurer.containerImage` and `scripts/searxng-up.sh`) with the per-install override `~/.runeweaver/searxng/settings.yml` carrying a random Flask secret (directory `0700`, file `0600`, enforced on every ensure with fail-closed logging; the bundled `Config/searxng/settings.yml` placeholder is a template only and is never mounted) plus a loopback-only publish (`127.0.0.1:<port>:8080`, host port derived from `searxng_url`: explicit port wins, else the scheme default — 80 for http, 443 for https — matching the probe; 8888 is the default configured URL's port) (following the runtime, daemon, start, run, poll cascade — worst case about 41s: daemon probe 5s plus bounded `system start` 8s plus recheck 5s plus container `start` 5s plus `run` 8s plus final poll 10s with 500 ms polls — single-flight in-process with container-name idempotency across serve-plus-CLI races), fails closed with guidance when still down, and leaves the container running after quit by design. To rotate the secret, delete the override file and re-ensure (or re-run `scripts/searxng-up.sh`), then recreate the container. Start it manually with `scripts/searxng-up.sh` when the engine cannot. `rune-weaver status` reports `reachable` or `unreachable` for the configured URL.

`web.search` is `readOnly` against SearXNG JSON (titles, URLs, snippets, bounded by the smaller of `limit` and `max_results`). `web.fetch` is `readOnly` with a five-hop redirect chain validated by the shared allowlist on every hop, a 1 MB byte cap, `finalUrl` always populated, and a typed envelope (`ok`, `auth_required` with a `browser.navigate` hint, `unsupported`).

`browser.navigate` (`readOnly`) opens a page in a fresh isolated Playwright context (no persistent profile, no cross-task storage) and returns distilled text plus snapshot refs in its envelope (`url`, `title`, `text`, `refs`, `truncated`, `authRequired`, manifest-only `downloads`). `browser.act` (`requiresApproval`) performs one validated action (click, fill, select, press, scroll) against a snapshot ref plus its URL, parking every call with target plus URL. `api.request` (`requiresApproval`) is the constrained GET/POST/PUT/DELETE path with an allowlisted header subset, 64KB body and 256KB response caps, and `ok` / `download` (manifest-only) / `preview` envelopes. Screenshots are an opt-in `includeScreenshot` on `browser.navigate` (default false), advertised only to vision-capable models and stripped from text-only history.

Search health shows in the same three places: `rune-weaver status` prints `reachable` or `unreachable`, the dashboard Profile menu shows a SearXNG row with Start and Stop, and the Settings Search pane shows the same controls plus health text.

### `[email]` — `[[email.accounts]]`

Repeat the `[[email.accounts]]` table once per account. Passwords live in the Keychain, never in TOML.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `name` | string | (required) | Account nickname (e.g. `"icloud"`). Must not be empty. |
| `type` | string | `"imap"` | Account type (e.g. `"imap"`). |
| `host` | string | (required) | IMAP hostname (e.g. `"imap.mail.me.com"`). Must not be empty. |
| `port` | integer | `993` | IMAP port. Must be 1–65535. |
| `username` | string | (required) | Login username. Must not be empty. |

### `[home]` — `[[home.homekit]]` / `[[home.home_assistant]]`

Both `[home.homekit]` and `[[home.homekit]]` spellings load; same for `home_assistant`.

`[[home.homekit]]`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `true` | Whether HomeKit control is enabled. |

`[[home.home_assistant]]`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `true` | Whether Home Assistant control is enabled. |
| `url` | string \| unset | unset | Home Assistant base URL (e.g. `http://homeassistant.local:8123`). Must be absolute when set. |
| `token_env` | string \| unset | unset | Env var (and Keychain key) holding the long-lived access token. |

### `[scheduler]` — `[[scheduler.jobs]]`

Repeat the `[[scheduler.jobs]]` table once per job. A job needs a `name`, a `prompt`, and at least one trigger: a cron `schedule` or a `poll_account` email-arrival rule. A job with both fires on either trigger. Disabled jobs are kept but never fire.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `name` | string | (required) | Job name (e.g. `"morning digest"`). Must not be empty. |
| `prompt` | string | (required) | Prompt executed when the job fires. Must not be empty. |
| `enabled` | bool | `true` | Whether the job fires. |
| `schedule` | string \| unset | unset | Cron expression (`minute hour day month weekday`, e.g. `"0 8 * * *"` for daily at 08:00) or `@hourly` / `@daily` / `@weekly` / `@monthly` / `@yearly`. Must parse when set. |
| `poll_account` | string \| unset | unset | Account nickname from `[[email.accounts]]` to watch for arrivals. Must not be empty when set. |
| `poll_query` | string \| unset | `""` | Free-text query for `email.search` (blank means most-recent). |
| `poll_mailbox` | string \| unset | unset | Mailbox to search (omitted means every selectable mailbox). |
| `poll_interval_seconds` | integer \| unset | `300` | Seconds between poll checks. Must be positive when set. |
| `poll_limit` | integer \| unset | `10` | Maximum hits per poll, clamped `1...50`. |

### `[plugins]`

Controls external rune plugin discovery and marketplace integration. Discovered and newly installed runes enter the system in a disabled state awaiting human review and approval before they can execute on the live bus.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `plugins_dir` | string | `"~/.runeweaver/plugins"` | Directory scanned for external rune packages. Must not be empty. |
| `marketplace_index_url` | string | `"https://raw.githubusercontent.com/ubenmackin/rune-weaver-marketplace/main/index.json"` | Remote marketplace catalog index URL. Must be a valid URL. |
| `auto_rescan` | bool | `true` | Whether to automatically scan the plugins directory on engine startup. |

## Provider Setup Guides

### MLX (local, Apple Silicon)

Requires Apple Silicon. Serve a model over an OpenAI-compatible API on port 8080 (e.g. with an MLX server), then:

```toml
[llm]
default_provider = "mlx"

[llm.providers.mlx]
enabled = true
model = "gemma-4-9b"
server_url = "http://localhost:8080"
```

Verify with `rune-weaver status` — the MLX provider pings `GET <server_url>/models` and reports availability. Chat streams over `/v1/chat/completions` (SSE); embeddings use `/v1/embeddings` when the server enables them (many MLX chat servers leave embeddings disabled).

### llama.cpp (local, any Mac)

Run `llama-server` (default port 8081), then:

```toml
[llm]
default_provider = "local"

[llm.providers.local]
enabled = true
provider_type = "llamacpp"
server_url = "http://localhost:8081"
```

Intel Macs should use this (or vLLM/cloud) — MLX requires Apple Silicon.

### OpenRouter (cloud fallback)

1. Create an API key at [openrouter.ai](https://openrouter.ai).
2. Expose it via environment or Keychain (see below) — never paste it into TOML:

```bash
export OPENROUTER_API_KEY="sk-or-..."
```

3. Configure:

```toml
[llm]
default_provider = "mlx"
fallback_provider = "openrouter"

[llm.providers.openrouter]
enabled = true
api_key_env = "OPENROUTER_API_KEY"
server_url = "https://openrouter.ai/api/v1"
```

The router tries `default_provider` first and falls through to `fallback_provider` on failure. Any OpenAI-compatible endpoint works the same way — point `server_url` at it and set `api_key_env`.

Every OpenAI-compatible request sends `User-Agent: rune-weaver/<version>` (matching the CLI version). Chat sessions also send `x-opencode-session: <session-UUID>` on chat, embeddings, and `GET /models` probes so a gateway can correlate turns; local providers (MLX, llama.cpp) never send the session header.

## Secrets Management

Lookup order in `SecretsManager.retrieve(key:)`:

1. **Environment variable** `key` (Docker/vault injection) — takes precedence.
2. **macOS Keychain** item `(service: com.runeweaver.secrets, account: key)`.

Writes always go to the Keychain. Secrets are never logged, never embedded in errors, and never written to `config.toml`.

Config keys that reference secrets (`api_key_env`, `token_env`, email passwords) only **name** the variable — `SecretsManager.resolve(_:)` fetches the value at execution time, so the LLM prompt never contains credentials.

Practical guide:

```bash
# Option A: environment (simplest for dev/Docker)
export OPENROUTER_API_KEY="sk-or-..."
export HA_TOKEN="your-home-assistant-token"

# Option B: Keychain (best for daily use on macOS)
# Store via the app/CLI secrets path under service "com.runeweaver.secrets",
# keyed by the same name (e.g. OPENROUTER_API_KEY, HA_TOKEN, per-account IMAP passwords).
```

Email account passwords are looked up by account — store each account's password in the Keychain rather than adding any key to TOML.

## Common Configurations

**Fully local (no cloud):**

```toml
[llm]
default_provider = "mlx"
# no fallback_provider key at all

[llm.providers.mlx]
enabled = true
model = "gemma-4-9b"
server_url = "http://localhost:8080"
```

No data leaves the machine.

**Local-first with cloud fallback (recommended):**

```toml
[llm]
default_provider = "mlx"
fallback_provider = "openrouter"
```

Local by default, cloud only when the local server is down.

**Cloud-only (e.g. Intel Mac without a local server):**

```toml
[llm]
default_provider = "openrouter"

[llm.providers.openrouter]
enabled = true
api_key_env = "OPENROUTER_API_KEY"
server_url = "https://openrouter.ai/api/v1"
```

**Quiet logging + custom paths:**

```toml
[engine]
log_level = "warning"

[memory]
vector_db_path = "~/.runeweaver/memory/vectors"
episodes_db_path = "~/.runeweaver/memory/episodes.db"

[sandbox]
container_base_image = "alpine:latest"
```
