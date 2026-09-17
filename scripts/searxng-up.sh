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
# Order mirrors the engine cascade (`SearXNGEnsurer.startExistingOrRun`): check
# the entry via `inspect` (falling back to `list --all`) before paying `start`
# or `run`. A present entry tries `start` first (fast path, no pull) and returns
# on success; a refused `start` removes the wedged entry with `rm`-first before
# the fresh `run` so the next `run` cannot hit "already exists". An absent entry
# goes straight to the fresh `run` without a doomed `start`. The fresh path pays
# an explicit `image pull` with a minutes budget only when the image is absent
# (skipped when cached, so a retry resumes downloaded layers), then a
# short-timeout `run` with the per-install settings mount. `rm`-first makes the
# `run` conflict impossible except for cross-process races recreating the name
# mid-flight; that residual wedge still revives via a `start` fallback before
# surfacing the conflict as a run failure. Pull timeouts are retryable (layers
# cached); pull failures point at Hub reachability while run failures carry the
# exit plus tail.
#
# The bundled `Config/searxng/settings.yml` is a template only: its
# `secret_key` is a placeholder. This script mints a random per-install Flask
# secret into `~/.runeweaver/searxng/settings.yml` (the preferred override
# path) on first run and mounts that, matching the engine ensure. Overrides
# carry a `# rune-weaver-template-version: <n>` marker comment; an existing
# file missing the marker or holding an older value is regenerated with a
# fresh secret and the container is recreated with `rm`-first plus a fresh
# `run` so the new settings and sizing boot. To rotate, delete the override
# file and re-run this script (the recreation mints the current marker), then
# recreate the container.
# The host port publishes loopback-only (`127.0.0.1`) because the engine has
# no auth; never publish SearXNG on all interfaces.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONTAINER_NAME="runeweaver-searxng"
# Tracked image (`:latest` by design) so fresh runs follow upstream without a
# version bump; pin via `SEARXNG_IMAGE=searxng/searxng:<tag>` when
# reproducibility matters. Keep in sync with `SearXNGEnsurer.containerImage`.
IMAGE="${SEARXNG_IMAGE:-searxng/searxng:latest}"
# Template version stamped into per-install overrides as a marker comment.
# Missing or older markers trigger a regenerate-with-fresh-secret plus a
# remove-first container recreate so the new settings and sizing boot.
# Keep in sync with `SearXNGEnsurer.settingsTemplateVersion` (2) and
# `settingsTemplateVersionMarkerPrefix`.
TEMPLATE_VERSION=2
TEMPLATE_MARKER="# rune-weaver-template-version:"
# Set when the override below migrates from a missing or older marker, so the
# container branch later skips the `start` fast path and recreates with
# `rm`-first plus a fresh `run` instead.
STALE_OVERRIDE=0
# Budgets mirror the engine ensurer so script and service converge: the pull
# pays minutes once on first run only (retries resume cached layers) while the
# fresh run stays short because it never hides a registry download. The image
# presence probe stays short so cached hosts never pay the pull budget. The
# engine adds a brief start settle (2s) after `start` before declaring refusal;
# the hatch trusts the `start` exit directly and needs no settle sleep. Keep in
# sync with `SearXNGEnsurer.containerImagePullTimeoutSeconds` (300),
# `containerImageInspectTimeoutSeconds` (8), `containerRunTimeoutSeconds` (8),
# `containerStartTimeoutSeconds` (5), and `containerStartSettleSeconds` (2).
PULL_TIMEOUT_SECS=300
INSPECT_TIMEOUT_SECS=8
RUN_TIMEOUT_SECS=8
START_TIMEOUT_SECS=5
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
        sed -E "s/^[[:space:]]*secret_key:.*/  secret_key: \"${SECRET_VALUE}\"/" "${BUNDLED_SETTINGS}" > "${TMP_FILE}"
        chmod 600 "${TMP_FILE}"
        # Stamp the current template marker so later runs can tell a stale
        # override from a current one without parsing YAML: replace any
        # existing marker line, otherwise insert after the first header line.
        if grep -qE "^[[:space:]]*#[[:space:]]*rune-weaver-template-version:" "${TMP_FILE}" 2>/dev/null; then
            TMP_STAMPED="$(mktemp)"
            sed -E "s|^[[:space:]]*#[[:space:]]*rune-weaver-template-version:.*|${TEMPLATE_MARKER} ${TEMPLATE_VERSION}|" "${TMP_FILE}" > "${TMP_STAMPED}"
            # Harden the staged secret before it ever reaches the destination:
            # the temp already arrives owner-only from mktemp, and this chmod
            # keeps it that way even under a permissive umask before the move.
            chmod 600 "${TMP_STAMPED}"
            mv "${TMP_STAMPED}" "${TMP_FILE}"
        else
            TMP_STAMPED="$(mktemp)"
            awk -v marker="${TEMPLATE_MARKER} ${TEMPLATE_VERSION}" 'NR==1{print; print marker; next} {print}' "${TMP_FILE}" > "${TMP_STAMPED}"
            chmod 600 "${TMP_STAMPED}"
            mv "${TMP_STAMPED}" "${TMP_FILE}"
        fi
        chmod 600 "${TMP_FILE}"
        mv "${TMP_FILE}" "${OVERRIDE_SETTINGS}"
    else
        # No template to render from: stage the fallback through an
        # owner-only temp so the secret never rests world-readable, even
        # briefly under a permissive umask, before the atomic move.
        TMP_FILE="$(mktemp)"
        cat > "${TMP_FILE}" <<EOF
# Rune Weaver — Per-install SearXNG settings (generated).
${TEMPLATE_MARKER} ${TEMPLATE_VERSION}
# Inherits upstream defaults; only the overrides below diverge (mirrors the
# bundled Config/searxng/settings.yml template and the engine fallback).
use_default_settings:
  engines:
    keep_only:
      - duckduckgo
      - brave
      - wikipedia
general:
  instance_name: "Rune Weaver SearXNG"
server:
  port: 8080
  bind_address: "0.0.0.0"
  secret_key: "${SECRET_VALUE}"
  limiter: false
  image_proxy: false
search:
  formats:
    - html
    - json
outgoing:
  request_timeout: 10.0
  max_request_timeout: 15.0
  pool_connections: 20
EOF
        chmod 600 "${TMP_FILE}"
        mv "${TMP_FILE}" "${OVERRIDE_SETTINGS}"
    fi
    # Fail closed on hardening failure: a world-readable secret must never
    # report success, so a chmod miss aborts instead of hiding behind `|| true`.
    if ! chmod 600 "${OVERRIDE_SETTINGS}"; then
        echo "Error: failed enforcing 0600 on ${OVERRIDE_SETTINGS}; refusing to continue with a world-readable secret." >&2
        exit 1
    fi
}

override_template_version() {
    # Prints the stamped template version from the override, or nothing when
    # the marker is missing. A malformed value also reads as missing so the
    # caller regenerates instead of trusting a half-written stamp.
    grep -E "^[[:space:]]*#[[:space:]]*rune-weaver-template-version:" "${OVERRIDE_SETTINGS}" 2>/dev/null \
        | sed -E 's/.*rune-weaver-template-version:[[:space:]]*([0-9]+).*/\1/' \
        | head -n 1 || true
}

override_needs_migration() {
    # True (0) when the override exists with a missing or older marker.
    # A missing file is not stale here: creation already mints the current
    # marker, so only an existing stale file forces the rm-first recreate.
    # Newer values never migrate so a forward-compatible install is kept.
    [ -f "${OVERRIDE_SETTINGS}" ] || return 1
    OVERRIDE_VER="$(override_template_version || true)"
    [ -z "${OVERRIDE_VER:-}" ] && return 0
    case "${OVERRIDE_VER}" in ''|*[!0-9]*) return 0 ;; esac
    [ "${OVERRIDE_VER}" -lt "${TEMPLATE_VERSION}" ]
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
        # Stale installs predate the marker entirely, so rebuild from the
        # current template with a fresh secret at 0600. The container branch
        # below recreates with rm-first plus a fresh run so the new settings
        # and sizing actually boot.
        if override_needs_migration; then
            SECRET_VALUE="$(generate_searxng_secret)"
            write_override_settings "${SECRET_VALUE}"
            echo "Regenerated stale SearXNG override at ${OVERRIDE_SETTINGS} (template v${TEMPLATE_VERSION})."
            STALE_OVERRIDE=1
            return 0
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

# Portable bounded run: GNU timeout, Homebrew gtimeout, then a background
# sleep-plus-kill so macOS (no timeout) never blocks unbounded. Returns the
# command exit code (124 on timeout with GNU timeout) so callers can tell a
# minutes-budget pull timeout (retry, layers cached) from a registry failure.
bounded_run() {
    # All variables stay function-local: the `system start` heal block below
    # reuses SLEEP_PID/WATCHER_PID (plus START_PID) and the pull/run captures
    # use PULL_CODE/RUN_CODE, so globals here would clobber (or be clobbered
    # by) those callers across nested or sequential runs.
    local BOUNDED_SECS="$1"
    local CMD_PID SLEEP_PID WATCHER_PID CMD_CODE
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "${BOUNDED_SECS}" "$@"
        return $?
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${BOUNDED_SECS}" "$@"
        return $?
    else
        "$@" &
        CMD_PID=$!
        sleep "${BOUNDED_SECS}" &
        SLEEP_PID=$!
        (wait "${SLEEP_PID}" 2>/dev/null; kill "${CMD_PID}" 2>/dev/null) &
        WATCHER_PID=$!
        wait "${CMD_PID}" 2>/dev/null
        CMD_CODE=$?
        kill "${SLEEP_PID}" 2>/dev/null || true
        wait "${SLEEP_PID}" 2>/dev/null || true
        kill "${WATCHER_PID}" 2>/dev/null || true
        wait "${WATCHER_PID}" 2>/dev/null || true
        return "${CMD_CODE}"
    fi
}

# Runtime resolves before any settings migration so a missing runtime exits
# before stamping a fresh marker: otherwise the migration would leave a
# current marker on disk with the old container, and the next run would skip
# the rm-first recreate while old sizing lingers.
RUNTIME=""
if command -v container >/dev/null 2>&1; then
    RUNTIME="container"
else
    echo "Error: 'container' (Apple Container CLI) was not found in PATH." >&2
    echo "Install the Apple Container CLI (https://github.com/apple/container), then retry. Docker is not supported." >&2
    exit 1
fi

ensure_override_settings

SETTINGS_PATH=""
if [ -f "${OVERRIDE_SETTINGS}" ]; then
    SETTINGS_PATH="${OVERRIDE_SETTINGS}"
elif [ -f "${BUNDLED_SETTINGS}" ]; then
    SETTINGS_PATH="${BUNDLED_SETTINGS}"
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
    # unbounded while the engine holds the minutes-scale readiness watch; the 8s
    # bound covers only this system start heal.
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

# Existence-aware branch mirrors `SearXNGEnsurer.containerEntryExists`: probe
# the tracked entry via `inspect` (precise exit 0 when present in any state),
# falling back to the `list --all` dump so a transient inspect miss cannot send
# a present entry down the absent fast path. Both probes run under the short
# start budget so a hung daemon cannot hang the hatch, matching the engine 5s
# probe. Plain `list` without `--all` shows only running entries, so a stopped
# entry would falsely read as absent and the next `run` would collide on the
# name. The list match uses token boundaries (same as
# `SearXNGEnsurer.containerExists`: any char outside [A-Za-z0-9_.-] delimits)
# so a longer sibling name never poses as the tracked entry while quoted JSON
# shapes like {"id":"runeweaver-searxng"} still match. Mirrors
# `SearXNGEnsurer.containerListAllArguments` plus `containerInspectArguments`
# plus `containerRemoveArguments` so script and engine never drift on verbs.
ENTRY_EXISTS=0
if bounded_run "${START_TIMEOUT_SECS}" "${RUNTIME}" inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    ENTRY_EXISTS=1
elif bounded_run "${START_TIMEOUT_SECS}" "${RUNTIME}" list --all 2>/dev/null | grep -qiE "(^|[^A-Za-z0-9_.-])${CONTAINER_NAME}([^A-Za-z0-9_.-]|$)"; then
    ENTRY_EXISTS=1
else
    ENTRY_EXISTS=0
fi

# Stale-template recreate mirrors `SearXNGEnsurer` stale handling: a migrated
# override must boot with rm-first plus a fresh run, skipping the `start` fast
# path so the new settings and sizing land. The remove precedes the run below,
# making the recreate conflict-impossible except for cross-process races that
# the fresh-run fallback still revives via `start`.
if [ "${STALE_OVERRIDE:-0}" -eq 1 ]; then
    echo "Stale SearXNG settings migrated; recreating ${CONTAINER_NAME} with new settings..."
    "${RUNTIME}" rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    ENTRY_EXISTS=0
fi

if [ "${ENTRY_EXISTS}" -eq 1 ]; then
    # Present entry: a stopped container from a prior run starts fastest with
    # the short start budget. Skipping the pull here keeps cached restarts fast
    # and matches the engine fast path.
    if bounded_run "${START_TIMEOUT_SECS}" "${RUNTIME}" start "${CONTAINER_NAME}" >/dev/null 2>&1; then
        echo "Started existing ${CONTAINER_NAME}."
        exit 0
    fi
    # Start refusal: remove the wedged entry with `rm`-first before the fresh
    # `run` below, mirroring `SearXNGEnsurer.removeStaleContainer`. Best-effort:
    # a concurrent remover win still leaves the fresh `run` safe.
    "${RUNTIME}" rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
else
    # Absent entry: go straight to the fresh `run` below without a doomed
    # `start` that would only burn the start budget and log a misleading
    # not-found failure. No `rm` needed when nothing exists.
    :
fi

# Explicit image pull ahead of `run` with the minutes budget, only when the
# image is absent. A retry resumes already-cached layers, so a timeout stays
# retryable instead of restarting from zero. The presence probe stays short so
# cached hosts never pay the pull budget.
# Presence probe uses the shared inspect budget (mirrors
# `containerImageInspectTimeoutSeconds`), not the minutes pull budget, so
# cached hosts skip the pull fast.
if ! bounded_run "${INSPECT_TIMEOUT_SECS}" "${RUNTIME}" image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "Pulling ${IMAGE} (first run, up to ${PULL_TIMEOUT_SECS}s; retry resumes cached layers)..."
    set +e
    PULL_OUTPUT="$(bounded_run "${PULL_TIMEOUT_SECS}" "${RUNTIME}" image pull "${IMAGE}" 2>&1)"
    PULL_CODE=$?
    set -e
    # GNU timeout reports 124 on expiry; the portable fallback kills the pull
    # instead (143/137), which is still a timeout with cached layers.
    if [ "${PULL_CODE}" -eq 124 ] || [ "${PULL_CODE}" -eq 143 ] || [ "${PULL_CODE}" -eq 137 ]; then
        echo "Error: image pull timed out after ${PULL_TIMEOUT_SECS}s. Retry — downloaded layers are cached." >&2
        exit 1
    elif [ "${PULL_CODE}" -ne 0 ]; then
        echo "Error: image pull failed. Check Docker Hub reachability, then retry." >&2
        printf '%s\n' "${PULL_OUTPUT}" >&2 || true
        exit 1
    fi
fi

# Fresh `run` needs no second `rm`: a refused `start` above already removed
# with `rm`-first, and an absent entry has nothing to remove. `rm`-first makes
# this `run` conflict-impossible except for cross-process races recreating the
# name between `rm` and `run`; that residual wedge still revives via the
# `start` fallback below before failing.

if [ -z "${SETTINGS_PATH}" ]; then
    echo "Error: no SearXNG settings found (checked ${OVERRIDE_SETTINGS} and ${BUNDLED_SETTINGS})." >&2
    echo "Refusing to start with image defaults, which lack formats:[html,json]." >&2
    echo "Restore Config/searxng/settings.yml or delete a corrupt override and re-run." >&2
    exit 1
fi
# Lean sizing for single-user search: one CPU and 512M is plenty; verify live
# usage with `container stats --no-stream runeweaver-searxng` before raising the ceiling.
RUN_ARGS=(run -d --cpus 1 --memory 512M --name "${CONTAINER_NAME}" -p "127.0.0.1:${PORT}:8080")
RUN_ARGS+=(-v "${SETTINGS_PATH}:/etc/searxng/settings.yml:ro")
echo "Using settings ${SETTINGS_PATH}."
RUN_ARGS+=("${IMAGE}")

# Short-timeout fresh run: the image is already cached above, so `run` only
# creates plus starts and never hides a registry download.
set +e
RUN_OUTPUT="$(bounded_run "${RUN_TIMEOUT_SECS}" "${RUNTIME}" "${RUN_ARGS[@]}" 2>&1)"
RUN_CODE=$?
set -e
if [ "${RUN_CODE}" -eq 0 ]; then
    echo "SearXNG starting at http://127.0.0.1:${PORT} (${CONTAINER_NAME} via ${RUNTIME})."
    echo "Leave it running after quit; stop explicitly with '${RUNTIME} stop ${CONTAINER_NAME}'."
    exit 0
fi
# `rm`-first above makes this conflict impossible except for cross-process races
# recreating the name between `rm` and `run`; that residual wedge is still
# startable, so fall back to `start` before surfacing the conflict as a run
# failure. Mirrors `SearXNGEnsurer.isWedgedContainer`: `already exists`/`already
# in use` alone imply the same-name wedge, but bare `conflict` without the
# container name could be an unrelated registry conflict, so require the name
# there.
if printf '%s' "${RUN_OUTPUT}" | grep -qiE 'already exists|already in use' || { printf '%s' "${RUN_OUTPUT}" | grep -qi 'conflict' && printf '%s' "${RUN_OUTPUT}" | grep -qiF -- "${CONTAINER_NAME}"; }; then
    echo "Fresh run hit a wedged same-name container; falling back to start..."
    if bounded_run "${START_TIMEOUT_SECS}" "${RUNTIME}" start "${CONTAINER_NAME}" >/dev/null 2>&1; then
        echo "Started wedged ${CONTAINER_NAME}."
        exit 0
    fi
fi
echo "Error: SearXNG run failed (exit ${RUN_CODE})." >&2
printf '%s\n' "${RUN_OUTPUT}" | tail -c 500 >&2 || true
exit 1
