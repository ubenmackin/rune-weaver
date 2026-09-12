# Configuration Reference

All non-sensitive settings live in `~/.runeweaver/config.toml`. Copy the example file to get started:

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
| `server_url` | string \| unset | unset | Local server URL (MLX / llama.cpp / vLLM). Must be an absolute URL (e.g. `http://localhost:8080`) when set. |
| `base_url` | string \| unset | unset | Cloud base URL for OpenAI-compatible endpoints. Must be an absolute URL when set. |
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
base_url = "https://openrouter.ai/api/v1"
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
base_url = "https://openrouter.ai/api/v1"
api_style = "responses"  # muse-spark family; omit or use "chat-completions" for glm, kimi, deepseek, mimo, hy, longcat
```

### `[memory]`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `vector_db_path` | string | `"~/.runeweaver/memory/vectors"` | JSON keyword store path for semantic memory (LanceDB-compatible shape); vector embeddings deferred pending an embeddings backend. Must not be empty. |
| `episodes_db_path` | string | `"~/.runeweaver/memory/episodes.db"` | SQLite path for episodic memory (conversation history). Must not be empty. |
| `embedding_model` | string | `"all-MiniLM-L6-v2"` | Embedding model identifier. Must not be empty. |

Vector-backed semantic memory is deferred until a local embeddings backend exists. Until then `remember` in chat (`remember <fact>`, `remember that <fact>`, `/remember <fact>`) stores facts in structured stores — profile facts plus keyword-only vector rows — so `memory facts` lists them without requiring embeddings.

### `[voice]`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `stt_provider` | string | `"whisper"` | Speech-to-text provider. Must not be empty. |
| `whisper_model` | string | `"base"` | Whisper model size (e.g. `tiny`, `base`, `small`). Must not be empty. |
| `tts_provider` | string | `"system"` | Text-to-speech provider (`system` = macOS `say` command). Must not be empty. |

### `[sandbox]`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `staging_path` | string | `"~/.runeweaver/sandbox"` | Staging directory for file writes awaiting approval (`pending/` vs `approved/`). Must not be empty. |
| `auto_approve_after` | integer | `5` | Successful executions before a write may auto-approve. Must be zero or positive. |

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
base_url = "https://openrouter.ai/api/v1"
```

The router tries `default_provider` first and falls through to `fallback_provider` on failure. Any OpenAI-compatible endpoint works the same way — point `base_url` at it and set `api_key_env`.

Every OpenAI-compatible request sends `User-Agent: rune-weaver/0.1.0` (matching the CLI version). Chat sessions also send `x-opencode-session: <session-UUID>` on chat, embeddings, and `GET /models` probes so a gateway can correlate turns; local providers (MLX, llama.cpp) never send the session header.

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
base_url = "https://openrouter.ai/api/v1"
```

**Quiet logging + custom paths:**

```toml
[engine]
log_level = "warning"

[memory]
vector_db_path = "~/.runeweaver/memory/vectors"
episodes_db_path = "~/.runeweaver/memory/episodes.db"

[sandbox]
staging_path = "~/.runeweaver/sandbox"
auto_approve_after = 0  # never auto-approve; always ask
```
