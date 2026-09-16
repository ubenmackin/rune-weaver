#!/usr/bin/env bash
set -euo pipefail

# Rune Weaver — Manual SearXNG escape hatch for local web search.
#
# Starts (or restarts) the `runeweaver-searxng` container the engine ensures
# on `serve` boot and first `web.search`. The engine leaves the container
# running after quit by design; use this script when the engine cannot start
# it (missing runtime, custom port, or corrupted container) or to recreate it
# from the bundled settings. Idempotent: a second run reuses the existing
# container instead of stacking duplicates, so concurrent serve-plus-CLI
# races serialize on the shared name.
#
# The bundled `Config/searxng/settings.yml` is a template only: its
# `secret_key` is a placeholder. This script mints a random per-install Flask
# secret into `~/.runeweaver/searxng/settings.yml` (the preferred override
# path) on first run and mounts that, matching the engine ensure. To rotate,
# delete the override file and re-run this script, then recreate the container.
# The host port publishes loopback-only (`127.0.0.1`) because the engine has
# no auth; never publish SearXNG on all interfaces.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONTAINER_NAME="runeweaver-searxng"
# Pinned image (never `:latest`) so supply-chain updates stay explicit; bump
# alongside `SearXNGEnsurer.containerImage` after verifying the digest.
IMAGE="${SEARXNG_IMAGE:-searxng/searxng:2025.9.1}"
# Port sync: the engine derives the publish port from [browser] searxng_url via
# SearXNGEnsurer.hostPort(from:) (explicit port wins, else 80 for http / 443 for
# https). This hatch mirrors it exactly: SEARXNG_URL (when set) wins with its
# explicit port else the scheme default, and SEARXNG_PORT applies only when no
# URL is set (else 8888). SEARXNG_PORT never overrides a URL-derived port, or
# the container would publish a different port than the engine probes.
PORT="${SEARXNG_PORT:-8888}"
if [ -n "${SEARXNG_URL:-}" ]; then
    URL_PORT="$(printf '%s' "${SEARXNG_URL}" | sed -E -n 's|^[A-Za-z][A-Za-z0-9+.-]*://(\[[^]]*\]|[^/:]+):([0-9]{1,5})(/.*)?$|\2|p')"
    if [ -n "${URL_PORT:-}" ]; then
        PORT="${URL_PORT}"
    else
        case "${SEARXNG_URL}" in
            https://*|HTTPS://*) PORT="443" ;;
            *) PORT="80" ;;
        esac
    fi
fi
BUNDLED_SETTINGS="${ROOT_DIR}/Config/searxng/settings.yml"
OVERRIDE_SETTINGS="${HOME}/.runeweaver/searxng/settings.yml"

generate_searxng_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
        return 0
    fi
    if [ -r /dev/urandom ]; then
        od -An -tx1 -N32 /dev/urandom | tr -d ' \t\n'
        echo
        return 0
    fi
    if command -v uuidgen >/dev/null 2>&1; then
        (uuidgen; uuidgen) | tr -d '\n-' | tr '[:upper:]' '[:lower:]'
        echo
        return 0
    fi
    # Fail closed when no CSPRNG helper exists: a predictable shell-random
    # Flask secret would weaken session signing, so refuse instead of minting
    # a weak key.
    echo "Error: no CSPRNG helper (openssl, /dev/urandom, or uuidgen) to mint the SearXNG secret_key." >&2
    exit 1
}

write_override_settings() {
    SECRET_VALUE="$1"
    if [ -f "${BUNDLED_SETTINGS}" ]; then
        TMP_FILE="$(mktemp)"
        sed "s/secret_key:.*/  secret_key: \"${SECRET_VALUE}\"/" "${BUNDLED_SETTINGS}" > "${TMP_FILE}"
        mv "${TMP_FILE}" "${OVERRIDE_SETTINGS}"
    else
        cat > "${OVERRIDE_SETTINGS}" <<EOF
# Rune Weaver — Per-install SearXNG settings (generated).
general:
  debug: false
  instance_name: "Rune Weaver SearXNG"
server:
  port: 8080
  bind_address: "0.0.0.0"
  secret_key: "${SECRET_VALUE}"
  limiter: false
  image_proxy: false
search:
  safe_search: 0
  autocomplete: ""
  formats:
    - html
    - json
engines:
  - name: duckduckgo
    engine: duckduckgo
    shortcut: ddg
  - name: brave
    engine: brave
    shortcut: br
  - name: wikipedia
    engine: wikipedia
    shortcut: wp
outgoing:
  request_timeout: 10.0
  max_request_timeout: 15.0
  pool_connections: 20
EOF
    fi
    # Fail closed on hardening failure: a world-readable secret must never
    # report success, so a chmod miss aborts instead of hiding behind `|| true`.
    if ! chmod 600 "${OVERRIDE_SETTINGS}"; then
        echo "Error: failed enforcing 0600 on ${OVERRIDE_SETTINGS}; refusing to continue with a world-readable secret." >&2
        exit 1
    fi
}

ensure_override_settings() {
    if [ -f "${OVERRIDE_SETTINGS}" ]; then
        # Harden pre-existing installs on every run, not just creation.
        if ! chmod 700 "$(dirname "${OVERRIDE_SETTINGS}")"; then
            echo "Error: failed enforcing 0700 on $(dirname "${OVERRIDE_SETTINGS}")." >&2
            exit 1
        fi
        if ! chmod 600 "${OVERRIDE_SETTINGS}"; then
            echo "Error: failed enforcing 0600 on ${OVERRIDE_SETTINGS}; refusing to continue with a world-readable secret." >&2
            exit 1
        fi
        if grep -q 'rune-weaver-local-search' "${OVERRIDE_SETTINGS}" 2>/dev/null || grep -q 'change-me-generate-per-install-secret' "${OVERRIDE_SETTINGS}" 2>/dev/null; then
            SECRET_VALUE="$(generate_searxng_secret)"
            write_override_settings "${SECRET_VALUE}"
            echo "Rotated per-install SearXNG secret at ${OVERRIDE_SETTINGS}."
        fi
        return 0
    fi
    mkdir -p "$(dirname "${OVERRIDE_SETTINGS}")"
    # Fail closed when the secret directory cannot be locked to 0700.
    if ! chmod 700 "$(dirname "${OVERRIDE_SETTINGS}")"; then
        echo "Error: failed enforcing 0700 on $(dirname "${OVERRIDE_SETTINGS}")." >&2
        exit 1
    fi
    SECRET_VALUE="$(generate_searxng_secret)"
    write_override_settings "${SECRET_VALUE}"
    echo "Generated per-install SearXNG secret at ${OVERRIDE_SETTINGS}."
}

ensure_override_settings

SETTINGS_PATH=""
if [ -f "${OVERRIDE_SETTINGS}" ]; then
    SETTINGS_PATH="${OVERRIDE_SETTINGS}"
elif [ -f "${BUNDLED_SETTINGS}" ]; then
    SETTINGS_PATH="${BUNDLED_SETTINGS}"
fi

RUNTIME=""
if command -v container >/dev/null 2>&1; then
    RUNTIME="container"
else
    echo "Error: 'container' (Apple Container CLI) was not found in PATH." >&2
    echo "Install the Apple Container CLI (https://github.com/apple/container), then retry. Docker is not supported." >&2
    exit 1
fi

# Container system daemon must answer before any container command. A fast
# `list` probe detects the down state via XPC/system-service text, then a
# best-effort `system start` heals it; the verify `list` confirms the heal so
# later `start`/`run` failures are container issues, not daemon outages.
DAEMON_OUTPUT="$("${RUNTIME}" list 2>&1 || true)"
if printf '%s' "${DAEMON_OUTPUT}" | grep -qiE 'XPC[^[:alnum:]]+connection|system[-_]service|system service'; then
    echo "Container system service is down; starting with '${RUNTIME} system start'..."
    # Bounded 8s heal on every platform: GNU timeout, Homebrew gtimeout, then a
    # portable background sleep-plus-kill so macOS (no timeout) never blocks
    # unbounded and stays inside the 41s cascade budget.
    if command -v timeout >/dev/null 2>&1; then
        timeout 8 "${RUNTIME}" system start || true
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 8 "${RUNTIME}" system start || true
    else
        "${RUNTIME}" system start &
        START_PID=$!
        # Portable timeout without GNU timeout: background `sleep` directly so
        # its PID stays tracked, then a watcher kills the start on expiry
        # while the parent kills the sleep on fast success. Killing the
        # watcher subshell alone would orphan the inner `sleep` and leave
        # `wait` holding the full 8s, so the sleep PID is reaped explicitly
        # and no orphan `sleep` remains either way.
        sleep 8 &
        SLEEP_PID=$!
        (wait "${SLEEP_PID}" 2>/dev/null; kill "${START_PID}" 2>/dev/null) &
        WATCHER_PID=$!
        wait "${START_PID}" 2>/dev/null || true
        kill "${SLEEP_PID}" 2>/dev/null || true
        wait "${SLEEP_PID}" 2>/dev/null || true
        kill "${WATCHER_PID}" 2>/dev/null || true
        wait "${WATCHER_PID}" 2>/dev/null || true
    fi
    echo "Verifying container system with '${RUNTIME} list'..."
    "${RUNTIME}" list >/dev/null 2>&1 || true
fi

# A stopped container from a prior run starts fastest; ignore the failure
# when none exists yet and fall through to `run`.
if "${RUNTIME}" start "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "Started existing ${CONTAINER_NAME}."
    exit 0
fi

# A half-created container with the same name blocks `run`; remove it first
# so retries never fail with "already exists" after an interrupted create.
"${RUNTIME}" rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true

if [ -z "${SETTINGS_PATH}" ]; then
    echo "Error: no SearXNG settings found (checked ${OVERRIDE_SETTINGS} and ${BUNDLED_SETTINGS})." >&2
    echo "Refusing to start with image defaults, which lack formats:[html,json]." >&2
    echo "Restore Config/searxng/settings.yml or delete a corrupt override and re-run." >&2
    exit 1
fi
RUN_ARGS=(run -d --name "${CONTAINER_NAME}" -p "127.0.0.1:${PORT}:8080")
RUN_ARGS+=(-v "${SETTINGS_PATH}:/etc/searxng/settings.yml:ro")
echo "Using settings ${SETTINGS_PATH}."
RUN_ARGS+=("${IMAGE}")

"${RUNTIME}" "${RUN_ARGS[@]}"
echo "SearXNG starting at http://127.0.0.1:${PORT} (${CONTAINER_NAME} via ${RUNTIME})."
echo "Leave it running after quit; stop explicitly with '${RUNTIME} stop ${CONTAINER_NAME}'."
