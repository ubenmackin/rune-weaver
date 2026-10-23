// Rune Weaver Dashboard — Network tab ([server] hostname, port, allowed_hosts).

import React from "react";
import type { SettingsResponse } from "../../api";
import {
  DEFAULT_SERVER_HOSTNAME,
  DEFAULT_SERVER_PORT,
  MAX_SERVER_ALLOWED_HOSTS,
  MAX_SERVER_ALLOWED_HOST_LENGTH,
  canonicalRestartHost,
  isLoopbackHostname,
  parseServerAllowedHostsText,
} from "../../api";
import {
  areServerAllowedHostsEqual,
  isServerBindPreset,
} from "./settingsHelpers";
import {
  SERVER_BIND_PRESETS,
  type LiveServerBind,
} from "./settingsTypes";

export interface NetworkTabProps {
  settings: SettingsResponse | null;
  serverHostname: string;
  setServerHostname: (value: string) => void;
  serverHostnameCustom: boolean;
  setServerHostnameCustom: (value: boolean) => void;
  serverPort: number | string;
  setServerPort: (value: number | string) => void;
  serverAllowedHostsText: string;
  setServerAllowedHostsText: (value: string) => void;
  serverAllowedHostsError: string | null;
  serverAllowedHostsCount: number;
  liveServerBind: LiveServerBind | null;
  serverRestartRequired: boolean;
  hasOwnerSession: boolean;
}

export function NetworkTab({
  settings,
  serverHostname,
  setServerHostname,
  serverHostnameCustom,
  setServerHostnameCustom,
  serverPort,
  setServerPort,
  serverAllowedHostsText,
  setServerAllowedHostsText,
  serverAllowedHostsError,
  serverAllowedHostsCount,
  liveServerBind,
  serverRestartRequired,
  hasOwnerSession,
}: NetworkTabProps): React.JSX.Element {
  // File holds the last saved values from GET/PUT; boot holds the still-live socket
  // from the pre-save snapshot (or /health when advertised); pending holds the unsaved
  // form.
  const fileHostname =
    typeof settings?.serverHostname === "string" && settings.serverHostname.trim()
      ? settings.serverHostname
      : DEFAULT_SERVER_HOSTNAME;
  const filePort =
    typeof settings?.serverPort === "number" ? settings.serverPort : DEFAULT_SERVER_PORT;
  const fileHosts = Array.isArray(settings?.serverAllowedHosts)
    ? (settings?.serverAllowedHosts as string[])
    : [];
  const bootHostname = liveServerBind?.hostname ?? fileHostname;
  const bootPort = liveServerBind?.port ?? filePort;
  const bootHosts = liveServerBind?.allowedHosts ?? fileHosts;
  const pendingHostname = serverHostname.trim();
  const pendingPort = Number(serverPort);
  const pendingHosts = parseServerAllowedHostsText(serverAllowedHostsText);
  const pendingHostsEqualFile = areServerAllowedHostsEqual(pendingHosts, fileHosts);
  const isDirty =
    canonicalRestartHost(pendingHostname) !==
      canonicalRestartHost(fileHostname) ||
    (Number.isInteger(pendingPort) ? pendingPort !== filePort : true) ||
    !pendingHostsEqualFile;
  const fileDiffersFromBoot =
    canonicalRestartHost(fileHostname) !==
      canonicalRestartHost(bootHostname) ||
    filePort !== bootPort ||
    !areServerAllowedHostsEqual(fileHosts, bootHosts);
  const restartVisible = serverRestartRequired || fileDiffersFromBoot;

  return (
    <div className="settings-section card">
      <div className="settings-section-title-group">
        <h3>Network</h3>
        <p className="settings-section-hint">
          HTTP bind interface, port, and exact-only allowed hosts from [server].
          Changes persist to config.toml and need a restart to take effect.
        </p>
      </div>

      {restartVisible ? (
        <div
          className="error-banner"
          data-testid="server-restart-banner"
          style={{
            backgroundColor: "rgba(237, 137, 54, 0.15)",
            border: "1px solid rgba(237, 137, 54, 0.4)",
            color: "#ed8936",
          }}
        >
          Restart required: network changes are saved but the live bind is still{" "}
          <code>
            {bootHostname}:{bootPort}
          </code>
          . Restart the engine to serve{" "}
          <code>
            {fileHostname}:{filePort}
          </code>
          .
        </div>
      ) : null}
      {isDirty && !restartVisible ? (
        <div
          className="muted text-sm"
          data-testid="server-pending-banner"
          style={{
            padding: "10px 14px",
            borderRadius: "8px",
            border: "1px solid var(--border-color, #2d3748)",
            marginBottom: "12px",
          }}
        >
          Unsaved network changes: pending{" "}
          <code>
            {pendingHostname || "(empty)"}:{String(serverPort) || "(empty)"}
          </code>{" "}
          vs saved{" "}
          <code>
            {fileHostname}:{filePort}
          </code>
          . Save, then restart to apply.
        </div>
      ) : null}

      <div id="server-bind-row" className="form-row">
        <div className="form-group flex-1">
          <label htmlFor="server-hostname-select">Bind interface</label>
          <select
            id="server-hostname-select"
            className="input-field"
            data-testid="server-hostname-select"
            value={
              serverHostnameCustom || !isServerBindPreset(serverHostname)
                ? "custom"
                : (SERVER_BIND_PRESETS.find(
                    (preset) =>
                      canonicalRestartHost(preset) ===
                      canonicalRestartHost(serverHostname)
                  ) ?? serverHostname.trim())
            }
            onChange={(e) => {
              const next = e.target.value;
              if (next === "custom") {
                // Entering custom mode preserves the preset value in the revealed input
                // instead of clearing to empty, so the pending bind never forces a
                // required-field error nor loses the preset until the operator edits it.
                setServerHostnameCustom(true);
              } else {
                setServerHostnameCustom(false);
                setServerHostname(next);
              }
            }}
          >
            <option value="127.0.0.1">127.0.0.1 (Loopback only, no token needed)</option>
            <option value="0.0.0.0">0.0.0.0 (All interfaces, LAN needs owner token)</option>
            <option value="custom">Custom</option>
          </select>
          <span className="form-group-hint">
            Which interface the engine listens on. This is separate from Allowed
            hosts below, which controls which Host headers the gate accepts.
          </span>
        </div>
        {serverHostnameCustom || !isServerBindPreset(serverHostname) ? (
          <div className="form-group flex-1">
            <label htmlFor="server-hostname">Bind address</label>
            <input
              id="server-hostname"
              type="text"
              className="input-field"
              data-testid="server-hostname"
              value={serverHostname}
              onChange={(e) => setServerHostname(e.target.value)}
              placeholder="127.0.0.1"
              required
            />
          </div>
        ) : null}
        <div className="form-group flex-1">
          <label htmlFor="server-port">Port</label>
          <input
            id="server-port"
            type="number"
            min={1}
            max={65535}
            step={1}
            className="input-field"
            data-testid="server-port"
            value={serverPort}
            onChange={(e) =>
              setServerPort(e.target.value === "" ? "" : Number(e.target.value))
            }
            placeholder={String(DEFAULT_SERVER_PORT)}
            required
          />
          <span className="form-group-hint">
            TCP port 1-65535. Saved to port under [server].
          </span>
        </div>
      </div>

      {!isLoopbackHostname(serverHostname) ? (
        <div
          className="muted text-sm"
          data-testid="server-lan-hint"
          style={{
            padding: "10px 14px",
            borderRadius: "8px",
            border: "1px solid var(--border-color, #2d3748)",
            margin: "12px 0",
          }}
        >
          A non-loopback bind serves on your local network and requires a resolvable owner
          token. Without one the save is refused (400) instead of silently downgrading.
          {hasOwnerSession ? (
            <span> An owner session is active in this tab.</span>
          ) : (
            <span>
              {" "}
              Generate one on the Mac Studio with <code>rune-weaver auth token generate</code>,
              then sign in before saving a LAN bind.
            </span>
          )}
        </div>
      ) : null}

      <div className="settings-subsection-header" style={{ marginTop: "20px" }}>
        <div className="settings-section-title-group">
          <h4 style={{ margin: "0 0 4px 0" }}>Allowed hosts</h4>
          <p className="settings-section-hint">
            Exact-only extra Host entries (max {MAX_SERVER_ALLOWED_HOSTS}, max{" "}
            {MAX_SERVER_ALLOWED_HOST_LENGTH} chars each). Lowercased and port-stripped on
            save; schemes, wildcards, CIDR, bare *, unbalanced brackets, and trailing
            dots are rejected.
          </p>
        </div>
        <div className="row">
          <span className="muted text-sm" data-testid="server-allowed-count">
            {serverAllowedHostsCount} {serverAllowedHostsCount === 1 ? "host" : "hosts"}
          </span>
        </div>
      </div>
      <div className="form-group" style={{ marginTop: "8px" }}>
        <label htmlFor="server-allowed-hosts-textarea">
          Allowed hosts, one per line{" "}
          <span className="muted text-sm">
            ({serverAllowedHostsCount} {serverAllowedHostsCount === 1 ? "host" : "hosts"})
          </span>
        </label>
        <textarea
          id="server-allowed-hosts-textarea"
          className="input-field server-allowed-hosts-textarea"
          data-testid="server-allowed-hosts"
          aria-label="Allowed hosts, one per line"
          value={serverAllowedHostsText}
          onChange={(e) => setServerAllowedHostsText(e.target.value)}
          placeholder="e.g. mac-studio.local"
          rows={6}
        />
        <span className="form-group-hint">
          One exact host per line. Blank lines are ignored. Entries are lowercased and
          port-stripped on save; schemes, wildcards, CIDR, bare *, unbalanced brackets,
          and trailing dots are rejected with line numbers.
        </span>
        {serverAllowedHostsError ? (
          <span
            className="form-group-hint"
            data-testid="server-allowed-error"
            style={{ color: "#f56565" }}
          >
            {serverAllowedHostsError}
          </span>
        ) : null}
      </div>
    </div>
  );
}
