# Monarch Money Community Plugin (`community.monarch-money`)

A Rune Weaver Python plugin for accessing and updating [Monarch Money](https://www.monarchmoney.com) financial data via [`monarchmoneycommunity`](https://github.com/bradleyseanf/monarchmoneycommunity).

## Features

- **Lean 4-Tool Surface**: Consolidated API allowing fine-grained tool toggles and per-tool permission overrides.
- **Sandboxed Subprocess Execution**: Runs under macOS Seatbelt confinement restricted to `api.monarch.com`.
- **Secrets Management**: Credentials injected securely at execution time via Rune Weaver `SecretsManager` and redacted from logs.
- **Dry-Run Previews**: Mutations support safe simulation mode before applying changes.

---

## Tools

| Tool | Permission | Description |
|---|---|---|
| `monarch.accounts` | `readOnly` | Query accounts, balances, institution connection health, and optional security holdings. |
| `monarch.transactions` | `readOnly` | Filter/search transactions, inspect single transaction splits/details, or list categories & tags. |
| `monarch.finances` | `readOnly` | Retrieve financial reports: `"budgets"`, `"cashflow"`, `"recurring"`, or `"goals"`. |
| `monarch.mutate` | `requiresApproval` | Approval-gated writes: update/create transactions, assign tags, adjust budgets, or request account refreshes. |

---

## Authentication & Credentials Setup

Configure your Monarch Money credentials in Rune Weaver Secrets (`Settings` -> `Secrets` in the web dashboard, or via keychain):

### Option 1: Bearer Token (Recommended)
Fastest and most reliable method. Bypasses interactive logins, CAPTCHAs, and 2FA prompts:
1. Log into [app.monarchmoney.com](https://app.monarchmoney.com) in your web browser.
2. Open Developer Tools (`Cmd+Option+I`), navigate to the **Network** tab, and filter by `graphql`.
3. Click any request, look at the **Request Headers**, and copy the token after `Authorization: Token `.
4. Save as secret key: `MONARCH_TOKEN`.

### Option 2: Browser Cookie
1. In Developer Tools Network tab, copy the value of the `Cookie` request header (must include `session_id` and `csrftoken`).
2. Save as secret key: `MONARCH_COOKIE`.

### Option 3: Email + Password (+ MFA Secret)
1. Save `MONARCH_EMAIL` and `MONARCH_PASSWORD`.
2. If your account has Two-Factor Authentication (MFA) enabled, get the TOTP text secret from Monarch Money under **Settings** -> **Security** -> **Two-Factor Authentication** -> **Two-factor text code**, and save it as `MONARCH_MFA_SECRET`.

---

## Installation

### Via Marketplace
1. In the Rune Weaver Dashboard, open **Settings** -> **Plugins**.
2. Select **Monarch Money** and click **Install**.
3. Click **Approve & Enable** to provision `.venv` and verify integrity.

### Via Manual Drop-in
1. Copy the `community.monarch-money` directory into `~/.runeweaver/plugins/`.
2. Click **Rescan Plugins** in the dashboard.
3. Review the declared tools and permissions, then click **Approve & Enable**.

---

## Session Cache

Session pickle lives at `.mm/runeweaver-monarch-session.pickle` under the plugin directory (owner-only `0600`).

---

## Supply-Chain Pins

`requirements.txt` pins `monarchmoneycommunity` plus transitive `gql`, `aiohttp`, `oathtool`, `graphql-core`, `anyio`, `backoff`, `attrs`, `multidict`, `yarl`, `frozenlist`, `aiosignal`, `propcache`, `aiohappyeyeballs`, `idna`, `sniffio`, `typing_extensions`, `exceptiongroup`, and `websockets` with `--hash` entries. Regenerate via `pip-compile --generate-hashes` without `--no-deps` and enable runs `pip install --require-hashes` failing closed on mismatch.
