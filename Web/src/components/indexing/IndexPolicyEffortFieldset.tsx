// Rune Weaver Dashboard — Effort presets and worker controls fieldset for IndexPolicyPanel.
import { INDEX_EFFORT_OPTIONS } from "./indexPolicyHelpers";
import { SwitchControl } from "../settings/SwitchControl";
import type { IndexConfigData } from "../../api";

interface IndexPolicyEffortFieldsetProps {
  effortReality: string;
  effortPreset: string;
  customWorkers: number;
  customMax: number;
  thermalBackoff: boolean;
  pauseOnBattery: boolean;
  updateConfig: (patch: Partial<IndexConfigData>) => void;
}

export default function IndexPolicyEffortFieldset({
  effortReality,
  effortPreset,
  customWorkers,
  customMax,
  thermalBackoff,
  pauseOnBattery,
  updateConfig,
}: IndexPolicyEffortFieldsetProps) {
  return (
    <fieldset id="index-effort-fieldset" className="index-effort-fieldset">
      <legend>Effort</legend>
      <p
        className="muted text-sm"
        data-testid="index-effort-reality"
        style={{ marginTop: 0 }}
      >
        {effortReality}
      </p>
      <div role="radiogroup" aria-label="Indexing effort">
        {INDEX_EFFORT_OPTIONS.map((option) => (
          <label key={option.id} className="toggle-label">
            <input
              type="radio"
              name="index-effort"
              value={option.id}
              checked={effortPreset === option.id}
              onChange={() => updateConfig({ effort: option.id })}
            />
            <span>{option.label}</span>
          </label>
        ))}
      </div>
      {effortPreset === "custom" ? (
        <div className="form-group" style={{ marginTop: 8 }}>
          <label htmlFor="index-custom-workers">Custom workers</label>
          <div className="row index-stepper">
            <button
              type="button"
              className="ghost"
              aria-label="Decrease workers"
              disabled={customWorkers <= 1}
              onClick={() =>
                updateConfig({ workers: Math.max(1, customWorkers - 1) })
              }
            >
              <span aria-hidden="true">−</span>
            </button>
            <input
              id="index-custom-workers"
              type="number"
              className="input-field index-stepper-input"
              inputMode="numeric"
              min={1}
              max={customMax}
              value={customWorkers}
              onChange={(event) => {
                const parsed = Number(event.target.value);
                if (!Number.isFinite(parsed)) return;
                updateConfig({
                  workers: Math.min(
                    customMax,
                    Math.max(1, Math.floor(parsed)),
                  ),
                });
              }}
            />
            <button
              type="button"
              className="ghost"
              aria-label="Increase workers"
              disabled={customWorkers >= customMax}
              onClick={() =>
                updateConfig({ workers: Math.min(customMax, customWorkers + 1) })
              }
            >
              <span aria-hidden="true">+</span>
            </button>
          </div>
          <p className="muted text-xs">
            Concurrent document extractors across the index.
          </p>
        </div>
      ) : null}

      <SwitchControl
        checked={thermalBackoff}
        onChange={(event) =>
          updateConfig({ thermalBackoff: event.target.checked })
        }
        label="Thermal backoff"
        hint="Thermal backoff"
      />

      <SwitchControl
        checked={pauseOnBattery}
        onChange={(event) =>
          updateConfig({ pauseOnBattery: event.target.checked })
        }
        label="Pause on battery"
        hint="Pause on battery"
      />
    </fieldset>
  );
}
