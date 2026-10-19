// Rune Weaver Dashboard — Voice Pipeline tab pane.
import { useState } from "react";
import { AdvancedDisclosure } from "./AdvancedDisclosure";
import {
  countVoiceAdvancedChanged,
  DEFAULT_VOICE_WHISPER_MODEL,
} from "./settingsAdvancedCounts";

export interface VoiceTabProps {
  voiceSTTProvider: string;
  setVoiceSTTProvider: (val: string) => void;
  voiceTTSProvider: string;
  setVoiceTTSProvider: (val: string) => void;
  voiceWhisperModel: string;
  setVoiceWhisperModel: (val: string) => void;
  validationError?: string | null;
}

export function VoiceTab({
  voiceSTTProvider,
  setVoiceSTTProvider,
  voiceTTSProvider,
  setVoiceTTSProvider,
  voiceWhisperModel,
  setVoiceWhisperModel,
  validationError = null,
}: VoiceTabProps) {
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const advancedChangedCount = countVoiceAdvancedChanged(voiceWhisperModel);

  // Reset restores the stock whisper model.
  const resetVoiceAdvanced = () => {
    setVoiceWhisperModel(DEFAULT_VOICE_WHISPER_MODEL);
  };

  return (
    <>
    <div className="settings-section card">
      <div className="settings-section-title-group">
        <h3>Voice Pipeline</h3>
        <p className="settings-section-hint">
          Speech-to-text and text-to-speech voice providers. Enablement lives on the voice tool toggle alone; this tab carries behavior knobs only.
        </p>
      </div>
      <div className="form-row" style={{ marginTop: "1rem" }}>
        <div className="form-group flex-1">
          <label htmlFor="stt-provider">Speech-to-Text (STT) Provider</label>
          <input
            id="stt-provider"
            type="text"
            className="input-field"
            value={voiceSTTProvider}
            onChange={(e) => setVoiceSTTProvider(e.target.value)}
          />
          <span className="form-group-hint">
            STT provider. Default is whisper.
          </span>
        </div>
        <div className="form-group flex-1">
          <label htmlFor="tts-provider">Text-to-Speech (TTS) Provider</label>
          <input
            id="tts-provider"
            type="text"
            className="input-field"
            value={voiceTTSProvider}
            onChange={(e) => setVoiceTTSProvider(e.target.value)}
          />
          <span className="form-group-hint">
            TTS provider. Default is system.
          </span>
        </div>
      </div>
    </div>
    <AdvancedDisclosure
      tabName="Voice"
      changedCount={advancedChangedCount}
      summary={
        advancedChangedCount > 0
          ? `${advancedChangedCount} advanced voice ${advancedChangedCount === 1 ? "setting" : "settings"} changed`
          : undefined
      }
      open={advancedOpen}
      onOpenChange={setAdvancedOpen}
      testId="advanced-voice"
      validationError={validationError}
      errorKeywords={["whisper"]}
      onReset={resetVoiceAdvanced}
    >
      <div className="settings-section card">
        <div className="form-group flex-1">
          <label htmlFor="whisper-model">Whisper Model</label>
          <input
            id="whisper-model"
            type="text"
            className="input-field"
            value={voiceWhisperModel}
            onChange={(e) => setVoiceWhisperModel(e.target.value)}
          />
          <span className="form-group-hint">
            Whisper model size (e.g. tiny, base, small). Default is base.
          </span>
        </div>
      </div>
    </AdvancedDisclosure>
    </>
  );
}

export default VoiceTab;
