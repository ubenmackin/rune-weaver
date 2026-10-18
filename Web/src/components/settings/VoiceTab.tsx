// Rune Weaver Dashboard — Voice Pipeline tab pane.

export interface VoiceTabProps {
  voiceSTTProvider: string;
  setVoiceSTTProvider: (val: string) => void;
  voiceTTSProvider: string;
  setVoiceTTSProvider: (val: string) => void;
  voiceWhisperModel: string;
  setVoiceWhisperModel: (val: string) => void;
}

export function VoiceTab({
  voiceSTTProvider,
  setVoiceSTTProvider,
  voiceTTSProvider,
  setVoiceTTSProvider,
  voiceWhisperModel,
  setVoiceWhisperModel,
}: VoiceTabProps) {
  return (
    <div className="settings-section card">
      <div className="settings-section-title-group">
        <h3>Voice Pipeline</h3>
        <p className="settings-section-hint">
          Speech-to-text and text-to-speech voice providers and models.
        </p>
      </div>
      <div className="form-row">
        <div className="form-group flex-1">
          <label htmlFor="stt-provider">Speech-to-Text (STT) Provider</label>
          <input
            id="stt-provider"
            type="text"
            className="input-field"
            value={voiceSTTProvider}
            onChange={(e) => setVoiceSTTProvider(e.target.value)}
          />
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
        </div>
        <div className="form-group flex-1">
          <label htmlFor="whisper-model">Whisper Model</label>
          <input
            id="whisper-model"
            type="text"
            className="input-field"
            value={voiceWhisperModel}
            onChange={(e) => setVoiceWhisperModel(e.target.value)}
          />
        </div>
      </div>
    </div>
  );
}

export default VoiceTab;
