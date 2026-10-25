// Rune Weaver Dashboard — Sources enablement fieldset for IndexPolicyPanel.
import { AlertTriangleIcon } from "../icons";
import { INDEX_SOURCES } from "./indexHelpers";
import { SwitchControl } from "../settings/SwitchControl";
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
          >
            <SwitchControl
              checked={checked}
              disabled={!config.enabled}
              label={`Index ${source.label}`}
              hint={source.label}
              onChange={(event) =>
                updateConfig({ [key]: event.target.checked } as Partial<IndexConfigData>)
              }
            />
            {source.hint ? (
              <span
                className="muted text-xs index-source-hint ml-1"
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
