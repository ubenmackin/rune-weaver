// Rune Weaver Dashboard — Tool config modal save handlers for Settings.

import { useRef, useState } from "react";
import {
  ApiError,
  DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS,
  DEFAULT_BROWSER_TIMEOUT_SECONDS,
  updateSettings,
} from "../../api";
import {
  validateBrowserFetchTimeoutSeconds,
  validateBrowserTimeoutSeconds,
  validateDesktopCaptureBounds,
  validateMediaTimeoutSeconds,
} from "./settingsHelpers";
import {
  buildDesktopPayload,
  buildFanoutPayload,
  buildMediaPayload,
} from "./settingsValidation";
import type { useSettingsFormState } from "./useSettingsFormState";

export interface UseSettingsSaveModalsProps {
  form: ReturnType<typeof useSettingsFormState>;
  pushSuccessToast: (msg: string) => void;
}

export function useSettingsSaveModals({
  form,
  pushSuccessToast,
}: UseSettingsSaveModalsProps) {
  const [configuringToolName, setConfiguringToolName] = useState<string | null>(null);

  const [mediaSaveLoading, setMediaSaveLoading] = useState(false);
  const [mediaModalError, setMediaModalError] = useState<string | null>(null);
  const mediaSaveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const [browserSaveLoading, setBrowserSaveLoading] = useState(false);
  const [browserModalError, setBrowserModalError] = useState<string | null>(null);
  const browserSaveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const [desktopSaveLoading, setDesktopSaveLoading] = useState(false);
  const [desktopModalError, setDesktopModalError] = useState<string | null>(null);
  const desktopSaveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const [fanoutSaveLoading, setFanoutSaveLoading] = useState(false);
  const [fanoutModalError, setFanoutModalError] = useState<string | null>(null);
  const fanoutSaveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const handleSaveMediaConfig = async () => {
    const mediaTimeoutError = validateMediaTimeoutSeconds(
      form.mediaTimeoutSeconds
    );
    if (mediaTimeoutError) {
      setMediaModalError(mediaTimeoutError);
      return;
    }
    setMediaSaveLoading(true);
    setMediaModalError(null);
    try {
      const updated = await updateSettings({
        media: buildMediaPayload(
          form.settings,
          form.mediaTimeoutSeconds,
          form.sonarrEnabled,
          form.sonarrUrl,
          form.sonarrApiKeyEnv,
          form.sonarrDefaultQuality,
          form.sonarrDefaultRoot,
          form.radarrEnabled,
          form.radarrUrl,
          form.radarrApiKeyEnv,
          form.radarrDefaultQuality,
          form.radarrDefaultRoot
        ),
      });
      form.populateForm(updated);
      pushSuccessToast("Media settings saved!");
      if (mediaSaveTimerRef.current !== null) {
        clearTimeout(mediaSaveTimerRef.current);
        mediaSaveTimerRef.current = null;
      }
      mediaSaveTimerRef.current = setTimeout(() => {
        mediaSaveTimerRef.current = null;
        setConfiguringToolName(null);
      }, 1000);
    } catch (err) {
      setMediaModalError(
        err instanceof ApiError ? err.message : "Failed to save media settings"
      );
    } finally {
      setMediaSaveLoading(false);
    }
  };

  const handleSaveBrowserConfig = async () => {
    const browserTimeoutError = validateBrowserTimeoutSeconds(
      form.browserTimeoutSeconds
    );
    if (browserTimeoutError) {
      setBrowserModalError(browserTimeoutError);
      return;
    }
    const browserFetchTimeoutError = validateBrowserFetchTimeoutSeconds(
      form.browserFetchTimeoutSeconds
    );
    if (browserFetchTimeoutError) {
      setBrowserModalError(browserFetchTimeoutError);
      return;
    }
    setBrowserSaveLoading(true);
    setBrowserModalError(null);
    try {
      const bTimeout = Number(form.browserTimeoutSeconds);
      const fTimeout = Number(form.browserFetchTimeoutSeconds);
      const updated = await updateSettings({
        browserTimeoutSeconds:
          isNaN(bTimeout) || bTimeout <= 0
            ? DEFAULT_BROWSER_TIMEOUT_SECONDS
            : bTimeout,
        browserFetchTimeoutSeconds:
          isNaN(fTimeout) || fTimeout <= 0
            ? DEFAULT_BROWSER_FETCH_TIMEOUT_SECONDS
            : fTimeout,
      });
      if (updated.browserTimeoutSeconds !== undefined) {
        form.setBrowserTimeoutSeconds(updated.browserTimeoutSeconds);
      }
      if (updated.browserFetchTimeoutSeconds !== undefined) {
        form.setBrowserFetchTimeoutSeconds(updated.browserFetchTimeoutSeconds);
      }
      pushSuccessToast("Web, browser & API settings saved!");
      if (browserSaveTimerRef.current !== null) {
        clearTimeout(browserSaveTimerRef.current);
        browserSaveTimerRef.current = null;
      }
      browserSaveTimerRef.current = setTimeout(() => {
        browserSaveTimerRef.current = null;
        setConfiguringToolName(null);
      }, 1000);
    } catch (err) {
      setBrowserModalError(
        err instanceof ApiError ? err.message : "Failed to save browser settings"
      );
    } finally {
      setBrowserSaveLoading(false);
    }
  };

  const handleSaveDesktopConfig = async () => {
    const desktopBoundsError = validateDesktopCaptureBounds(
      form.desktopMaxImageDimension,
      form.desktopJpegQuality
    );
    if (desktopBoundsError) {
      setDesktopModalError(desktopBoundsError);
      return;
    }
    setDesktopSaveLoading(true);
    setDesktopModalError(null);
    try {
      const updated = await updateSettings({
        desktop: buildDesktopPayload(
          form.desktopMaxImageDimension,
          form.desktopJpegQuality,
          form.desktopBlockedAppsText
        ),
      });
      form.populateForm(updated);
      pushSuccessToast("Desktop settings saved!");
      if (desktopSaveTimerRef.current !== null) {
        clearTimeout(desktopSaveTimerRef.current);
        desktopSaveTimerRef.current = null;
      }
      desktopSaveTimerRef.current = setTimeout(() => {
        desktopSaveTimerRef.current = null;
        setConfiguringToolName(null);
      }, 1000);
    } catch (err) {
      setDesktopModalError(
        err instanceof ApiError ? err.message : "Failed to save desktop settings"
      );
    } finally {
      setDesktopSaveLoading(false);
    }
  };

  const handleSaveFanoutConfig = async () => {
    setFanoutSaveLoading(true);
    setFanoutModalError(null);
    try {
      const updated = await updateSettings({
        fanout: buildFanoutPayload(
          form.fanoutLoadedRef.current,
          form.fanoutMaxWorkers,
          form.fanoutWorkerTimeoutSeconds,
          form.fanoutFullTools
        ),
      });
      form.populateForm(updated);
      pushSuccessToast("Fan-out settings saved!");
      if (fanoutSaveTimerRef.current !== null) {
        clearTimeout(fanoutSaveTimerRef.current);
        fanoutSaveTimerRef.current = null;
      }
      fanoutSaveTimerRef.current = setTimeout(() => {
        fanoutSaveTimerRef.current = null;
        setConfiguringToolName(null);
      }, 1000);
    } catch (err) {
      setFanoutModalError(
        err instanceof ApiError ? err.message : "Failed to save fan-out settings"
      );
    } finally {
      setFanoutSaveLoading(false);
    }
  };

  return {
    configuringToolName,
    setConfiguringToolName,
    mediaSaveLoading,
    mediaModalError,
    browserSaveLoading,
    browserModalError,
    desktopSaveLoading,
    desktopModalError,
    fanoutSaveLoading,
    fanoutModalError,
    handleSaveMediaConfig,
    handleSaveBrowserConfig,
    handleSaveDesktopConfig,
    handleSaveFanoutConfig,
  };
}
