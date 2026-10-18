// Rune Weaver Dashboard — Sources enablement fieldset for IndexPolicyPanel.
import { AlertTriangleIcon } from "../icons";
import { INDEX_SOURCES } from "./indexHelpers";
import type { IndexConfigData } from "../../api";

interface IndexPolicySourcesFieldsetProps {
  config: IndexConfigData;
  updateConfig: (patch: Partial<IndexConfigData>) => void;
}

export default function IndexPolicySourcesFieldset({
  config,
  updateConfig,
}: IndexPolicySourcesFieldsetProps) {
  return (
    <fieldset className="index-sources-fieldset">
      <legend>Sources</legend>
      {INDEX_SOURCES.map((source) => {
        const checkedByKind: Record<string, boolean> = {
          files: config.files,
          mail: config.mail,
          messages: config.messages,
          calendars: config.calendars,
          reminders: config.reminders,
        };
        const checked = checkedByKind[source.kind] ?? false;
        const keyByKind: Record<string, string> = {
          files: "files",
          mail: "mail",
          messages: "messages",
          calendars: "calendars",
          reminders: "reminders",
        };
        const key = keyByKind[source.kind] ?? source.kind;
        return (
          <div
            key={source.kind}
            className="index-source-row"
            style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}
          >
            <label className="toggle-label">
              <input
                type="checkbox"
                checked={checked}
                disabled={!config.enabled}
                aria-label={`Index ${source.label}`}
                onChange={(event) =>
                  updateConfig({ [key]: event.target.checked } as Partial<IndexConfigData>)
                }
              />
              <span>{source.label}</span>
            </label>
            {source.hint ? (
              <span
                className="muted text-xs index-source-hint"
                style={{ marginLeft: 4 }}
              >
                <AlertTriangleIcon size={12} /> {source.hint}
              </span>
            ) : null}
          </div>
        );
      })}
    </fieldset>
  );
}
