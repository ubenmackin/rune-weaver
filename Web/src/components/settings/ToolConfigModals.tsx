// Rune Weaver Dashboard — Coordinator for Tool Configuration Modals.

import React from "react";
import { CloseIcon } from "../icons";
import Modal from "../Modal";
import { BrowserConfigModal } from "./BrowserConfigModal";
import { DesktopConfigModal } from "./DesktopConfigModal";
import { FanoutConfigModal } from "./FanoutConfigModal";
import { MediaConfigModal } from "./MediaConfigModal";
import type { SettingsTab } from "./settingsTypes";

export interface ToolConfigModalsProps {
  configuringToolName: string | null;
  setConfiguringToolName: (name: string | null) => void;
  setActiveTab: (tab: SettingsTab) => void;

  // Browser config props
  browserSaveLoading: boolean;
  browserModalError: string | null;
  browserTimeoutSeconds: number | string;
  setBrowserTimeoutSeconds: (val: string) => void;
  browserFetchTimeoutSeconds: number | string;
  setBrowserFetchTimeoutSeconds: (val: string) => void;
  handleSaveBrowserConfig: () => Promise<void>;

  // Media config props
  mediaSaveLoading: boolean;
  mediaModalError: string | null;
  sonarrEnabled: boolean;
  setSonarrEnabled: (enabled: boolean) => void;
  sonarrUrl: string;
  setSonarrUrl: (url: string) => void;
  sonarrApiKeyEnv: string;
  setSonarrApiKeyEnv: (env: string) => void;
  sonarrDefaultQuality: string;
  setSonarrDefaultQuality: (quality: string) => void;
  sonarrDefaultRoot: string;
  setSonarrDefaultRoot: (root: string) => void;
  radarrEnabled: boolean;
  setRadarrEnabled: (enabled: boolean) => void;
  radarrUrl: string;
  setRadarrUrl: (url: string) => void;
  radarrApiKeyEnv: string;
  setRadarrApiKeyEnv: (env: string) => void;
  radarrDefaultQuality: string;
  setRadarrDefaultQuality: (quality: string) => void;
  radarrDefaultRoot: string;
  setRadarrDefaultRoot: (root: string) => void;
  mediaTimeoutSeconds: number | string;
  setMediaTimeoutSeconds: (timeout: string) => void;
  handleSaveMediaConfig: () => Promise<void>;
  secretStatus: Record<string, boolean>;
  handleOpenStoreSecretModal: (
    secretKey: string,
    label: string,
    isUpdate: boolean
  ) => void;

  // Desktop config props
  desktopSaveLoading: boolean;
  desktopModalError: string | null;
  desktopMaxImageDimension: number | string;
  setDesktopMaxImageDimension: (val: number | "") => void;
  desktopJpegQuality: number | string;
  setDesktopJpegQuality: (val: number | "") => void;
  desktopBlockedAppsText: string;
  setDesktopBlockedAppsText: (val: string) => void;
  handleSaveDesktopConfig: () => Promise<void>;

  // Fanout config props
  fanoutSaveLoading: boolean;
  fanoutModalError: string | null;
  fanoutMaxWorkers: number | string;
  setFanoutMaxWorkers: (val: number | "") => void;
  fanoutWorkerTimeoutSeconds: number | string;
  setFanoutWorkerTimeoutSeconds: (val: number | "") => void;
  fanoutFullTools: boolean;
  setFanoutFullTools: (val: boolean) => void;
  handleSaveFanoutConfig: () => Promise<void>;
}

export function ToolConfigModals({
  configuringToolName,
  setConfiguringToolName,
  setActiveTab,
  browserSaveLoading,
  browserModalError,
  browserTimeoutSeconds,
  setBrowserTimeoutSeconds,
  browserFetchTimeoutSeconds,
  setBrowserFetchTimeoutSeconds,
  handleSaveBrowserConfig,
  mediaSaveLoading,
  mediaModalError,
  sonarrEnabled,
  setSonarrEnabled,
  sonarrUrl,
  setSonarrUrl,
  sonarrApiKeyEnv,
  setSonarrApiKeyEnv,
  sonarrDefaultQuality,
  setSonarrDefaultQuality,
  sonarrDefaultRoot,
  setSonarrDefaultRoot,
  radarrEnabled,
  setRadarrEnabled,
  radarrUrl,
  setRadarrUrl,
  radarrApiKeyEnv,
  setRadarrApiKeyEnv,
  radarrDefaultQuality,
  setRadarrDefaultQuality,
  radarrDefaultRoot,
  setRadarrDefaultRoot,
  mediaTimeoutSeconds,
  setMediaTimeoutSeconds,
  handleSaveMediaConfig,
  secretStatus,
  handleOpenStoreSecretModal,
  desktopSaveLoading,
  desktopModalError,
  desktopMaxImageDimension,
  setDesktopMaxImageDimension,
  desktopJpegQuality,
  setDesktopJpegQuality,
  desktopBlockedAppsText,
  setDesktopBlockedAppsText,
  handleSaveDesktopConfig,
  fanoutSaveLoading,
  fanoutModalError,
  fanoutMaxWorkers,
  setFanoutMaxWorkers,
  fanoutWorkerTimeoutSeconds,
  setFanoutWorkerTimeoutSeconds,
  fanoutFullTools,
  setFanoutFullTools,
  handleSaveFanoutConfig,
}: ToolConfigModalsProps): React.JSX.Element | null {
  if (configuringToolName === null) return null;

  const isBrowserTool =
    configuringToolName === "browser.navigate" ||
    configuringToolName === "browser.act" ||
    configuringToolName === "web.fetch" ||
    configuringToolName === "web.search" ||
    configuringToolName === "api.request";

  const isMediaTool =
    configuringToolName === "media.arr" ||
    configuringToolName === "media.arr.read";

  const isDesktopTool =
    configuringToolName === "desktop" ||
    configuringToolName === "desktop.screenshot" ||
    configuringToolName === "desktop.action";

  const isFanoutTool =
    configuringToolName === "fanout.run" ||
    configuringToolName.startsWith("fanout.");

  if (isBrowserTool) {
    return (
      <BrowserConfigModal
        isOpen={true}
        onClose={() => setConfiguringToolName(null)}
        onManageSecurityPolicy={() => {
          setActiveTab("access");
          setConfiguringToolName(null);
        }}
        browserSaveLoading={browserSaveLoading}
        browserModalError={browserModalError}
        browserTimeoutSeconds={browserTimeoutSeconds}
        setBrowserTimeoutSeconds={setBrowserTimeoutSeconds}
        browserFetchTimeoutSeconds={browserFetchTimeoutSeconds}
        setBrowserFetchTimeoutSeconds={setBrowserFetchTimeoutSeconds}
        handleSaveBrowserConfig={handleSaveBrowserConfig}
      />
    );
  }

  if (isMediaTool) {
    return (
      <MediaConfigModal
        isOpen={true}
        onClose={() => setConfiguringToolName(null)}
        mediaSaveLoading={mediaSaveLoading}
        mediaModalError={mediaModalError}
        sonarrEnabled={sonarrEnabled}
        setSonarrEnabled={setSonarrEnabled}
        sonarrUrl={sonarrUrl}
        setSonarrUrl={setSonarrUrl}
        sonarrApiKeyEnv={sonarrApiKeyEnv}
        setSonarrApiKeyEnv={setSonarrApiKeyEnv}
        sonarrDefaultQuality={sonarrDefaultQuality}
        setSonarrDefaultQuality={setSonarrDefaultQuality}
        sonarrDefaultRoot={sonarrDefaultRoot}
        setSonarrDefaultRoot={setSonarrDefaultRoot}
        radarrEnabled={radarrEnabled}
        setRadarrEnabled={setRadarrEnabled}
        radarrUrl={radarrUrl}
        setRadarrUrl={setRadarrUrl}
        radarrApiKeyEnv={radarrApiKeyEnv}
        setRadarrApiKeyEnv={setRadarrApiKeyEnv}
        radarrDefaultQuality={radarrDefaultQuality}
        setRadarrDefaultQuality={setRadarrDefaultQuality}
        radarrDefaultRoot={radarrDefaultRoot}
        setRadarrDefaultRoot={setRadarrDefaultRoot}
        mediaTimeoutSeconds={mediaTimeoutSeconds}
        setMediaTimeoutSeconds={setMediaTimeoutSeconds}
        handleSaveMediaConfig={handleSaveMediaConfig}
        secretStatus={secretStatus}
        handleOpenStoreSecretModal={handleOpenStoreSecretModal}
      />
    );
  }

  if (isDesktopTool) {
    return (
      <DesktopConfigModal
        isOpen={true}
        onClose={() => setConfiguringToolName(null)}
        desktopSaveLoading={desktopSaveLoading}
        desktopModalError={desktopModalError}
        desktopMaxImageDimension={desktopMaxImageDimension}
        setDesktopMaxImageDimension={setDesktopMaxImageDimension}
        desktopJpegQuality={desktopJpegQuality}
        setDesktopJpegQuality={setDesktopJpegQuality}
        desktopBlockedAppsText={desktopBlockedAppsText}
        setDesktopBlockedAppsText={setDesktopBlockedAppsText}
        handleSaveDesktopConfig={handleSaveDesktopConfig}
      />
    );
  }

  if (isFanoutTool) {
    return (
      <FanoutConfigModal
        isOpen={true}
        onClose={() => setConfiguringToolName(null)}
        fanoutSaveLoading={fanoutSaveLoading}
        fanoutModalError={fanoutModalError}
        fanoutMaxWorkers={fanoutMaxWorkers}
        setFanoutMaxWorkers={setFanoutMaxWorkers}
        fanoutWorkerTimeoutSeconds={fanoutWorkerTimeoutSeconds}
        setFanoutWorkerTimeoutSeconds={setFanoutWorkerTimeoutSeconds}
        fanoutFullTools={fanoutFullTools}
        setFanoutFullTools={setFanoutFullTools}
        handleSaveFanoutConfig={handleSaveFanoutConfig}
      />
    );
  }

  // Honest fallback for any future hasConfig tool without a dedicated
  // editor: the Configure button stays flag-driven, so an unmapped name
  // must explain itself instead of rendering nothing on click.
  return (
    <Modal
      label={`Configure ${configuringToolName}`}
      onClose={() => setConfiguringToolName(null)}
      containerClassName="modal-container"
    >
      <div className="modal-header">
        <h3>Configure {configuringToolName}</h3>
        <button
          type="button"
          className="icon-button"
          onClick={() => setConfiguringToolName(null)}
          aria-label="Close"
        >
          <CloseIcon size={16} />
        </button>
      </div>
      <div className="modal-body">
        <p className="muted text-sm">
          No configuration UI is available for &ldquo;
          {configuringToolName}&rdquo; yet. This tool reports settings
          support, but the dashboard has no editor for it, so nothing was
          changed.
        </p>
      </div>
      <div
        className="modal-footer"
        style={{ display: "flex", justifyContent: "flex-end", gap: "8px" }}
      >
        <button
          type="button"
          className="primary"
          onClick={() => setConfiguringToolName(null)}
        >
          Close
        </button>
      </div>
    </Modal>
  );
}
