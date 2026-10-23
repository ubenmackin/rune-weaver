// Rune Weaver Dashboard — Email Accounts tab pane.

import { useState } from "react";
import type { EmailAccountData } from "../../api";
import { CheckIcon, KeyIcon, MailIcon, PlusIcon, TrashIcon } from "../icons";
import { AdvancedDisclosure } from "./AdvancedDisclosure";
import { getEmailPasswordEnv } from "./settingsHelpers";
import type { EmailEntry } from "./settingsTypes";

export interface EmailTabProps {
  emailAccountsList: EmailEntry[];
  handleAddEmailAccount: () => void;
  handleRemoveEmailAccount: (id: string) => void;
  handleEmailFieldChange: (
    id: string,
    field: keyof EmailAccountData,
    value: string | number,
  ) => void;
  secretStatus: Record<string, boolean>;
  onOpenStoreSecretModal: (
    keyEnv: string,
    title: string,
    isStored: boolean,
  ) => void;
  validationError?: string | null;
}

function matchesAdvancedError(message: string | null | undefined): boolean {
  if (!message) return false;
  const lowered = message.toLowerCase();
  return (
    lowered.includes("smtp") ||
    lowered.includes("batch") ||
    lowered.includes("watermark") ||
    lowered.includes("archive") ||
    lowered.includes("uid")
  );
}

export function EmailTab({
  emailAccountsList,
  handleAddEmailAccount,
  handleRemoveEmailAccount,
  handleEmailFieldChange,
  secretStatus,
  onOpenStoreSecretModal,
  validationError,
}: EmailTabProps) {
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const advancedError = matchesAdvancedError(validationError)
    ? validationError
    : null;

  const handleResetAdvanced = () => {
    for (const item of emailAccountsList) {
      handleEmailFieldChange(item.id, "smtpHost", "");
      handleEmailFieldChange(item.id, "smtpPort", "");
      handleEmailFieldChange(item.id, "smtpSecurity", "auto");
    }
  };

  return (
    <div className="settings-section card" id="email-pane">
      <div className="settings-section-header">
        <div className="settings-section-title-group">
          <h3>Email Accounts</h3>
          <p className="settings-section-hint">
            Configure IMAP email accounts for background monitoring and automated schedules.
          </p>
        </div>
        <div className="row">
          <button
            type="button"
            id="email-add-account"
            className="ghost icon-text-btn"
            onClick={handleAddEmailAccount}
          >
            <PlusIcon size={14} />
            <span>Add Account</span>
          </button>
        </div>
      </div>

      {emailAccountsList.length === 0 ? (
        <div className="empty-state-box">
          <MailIcon size={32} />
          <p>No email accounts configured yet.</p>
          <button
            type="button"
            className="primary icon-text-btn"
            onClick={handleAddEmailAccount}
          >
            <PlusIcon size={14} />
            <span>Configure First Email Account</span>
          </button>
        </div>
      ) : (
        <div className="email-accounts-list">
          {emailAccountsList.map((item) => {
            const acc = item.account;
            const passwordEnv = getEmailPasswordEnv(acc.name);
            return (
              <div key={item.id} className="email-account-card">
                <div className="email-card-header">
                  <div className="email-card-title">
                    <MailIcon size={18} />
                    <h4>{acc.name || "Untitled Account"}</h4>
                    <span className="email-card-type-badge">{acc.type}</span>
                  </div>
                  <button
                    type="button"
                    className="icon-button danger"
                    onClick={() => handleRemoveEmailAccount(item.id)}
                    title={`Delete account ${acc.name}`}
                    aria-label={`Delete account ${acc.name}`}
                  >
                    <TrashIcon size={14} />
                  </button>
                </div>

                <div className="email-fields-grid">
                  <div className="form-group">
                    <label htmlFor={`email-name-${item.id}`}>Nickname</label>
                    <input
                      id={`email-name-${item.id}`}
                      type="text"
                      className="input-field"
                      value={acc.name}
                      onChange={(e) =>
                        handleEmailFieldChange(item.id, "name", e.target.value)
                      }
                      placeholder="e.g. icloud, work"
                      required
                    />
                  </div>

                  <div className="form-group">
                    <label htmlFor={`email-type-${item.id}`}>Type</label>
                    <select
                      id={`email-type-${item.id}`}
                      className="input-field"
                      value={acc.type}
                      onChange={(e) =>
                        handleEmailFieldChange(item.id, "type", e.target.value)
                      }
                    >
                      <option value="imap">IMAP</option>
                      <option value="pop3">POP3</option>
                    </select>
                  </div>

                  <div className="form-group">
                    <label htmlFor={`email-host-${item.id}`}>Host</label>
                    <input
                      id={`email-host-${item.id}`}
                      type="text"
                      className="input-field"
                      value={acc.host}
                      onChange={(e) =>
                        handleEmailFieldChange(item.id, "host", e.target.value)
                      }
                      placeholder="imap.mail.me.com"
                      required
                    />
                  </div>

                  <div className="form-group">
                    <label htmlFor={`email-port-${item.id}`}>Port</label>
                    <input
                      id={`email-port-${item.id}`}
                      type="number"
                      className="input-field"
                      value={acc.port}
                      onChange={(e) =>
                        handleEmailFieldChange(item.id, "port", e.target.value)
                      }
                      placeholder="993"
                      required
                    />
                  </div>

                  <div className="form-group">
                    <label htmlFor={`email-user-${item.id}`}>Username / Email</label>
                    <input
                      id={`email-user-${item.id}`}
                      type="text"
                      className="input-field"
                      value={acc.username}
                      onChange={(e) =>
                        handleEmailFieldChange(item.id, "username", e.target.value)
                      }
                      placeholder="user@example.com"
                      required
                    />
                  </div>
                </div>

                <div className="email-env-hint" style={{ display: "flex", alignItems: "center", justifyContent: "space-between", flexWrap: "wrap", gap: "8px" }}>
                  <div>
                    <span>Password resolved via SecretsManager from: </span>
                    <code>{passwordEnv}</code>
                  </div>
                  <div style={{ display: "flex", alignItems: "center", gap: "8px" }}>
                    {secretStatus[passwordEnv] ? (
                      <span className="keychain-status-badge stored">
                        <CheckIcon size={12} /> Stored in Keychain
                      </span>
                    ) : (
                      <span className="keychain-status-badge missing">
                        Not Set in Keychain
                      </span>
                    )}
                    <button
                      type="button"
                      className="keychain-action-btn"
                      onClick={() =>
                        onOpenStoreSecretModal(
                          passwordEnv,
                          `Password for ${acc.name || "Email Account"}`,
                          !!secretStatus[passwordEnv]
                        )
                      }
                      title={
                        secretStatus[passwordEnv]
                          ? `Update password for ${acc.name} in Keychain`
                          : `Store password for ${acc.name} in Keychain`
                      }
                    >
                      <KeyIcon size={12} />
                      <span>
                        {secretStatus[passwordEnv]
                          ? "Update Password in Keychain"
                          : "Store Password to Keychain"}
                      </span>
                    </button>
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      )}
      <AdvancedDisclosure
        tabName="Email"
        open={advancedOpen}
        onOpenChange={setAdvancedOpen}
        validationError={advancedError}
        onReset={handleResetAdvanced}
      >
        <div className="email-accounts-list">
          {emailAccountsList.length === 0 ? (
            <p className="muted text-sm">
              Add an account above to tune delivery overrides, batch sizes, and archive handling.
            </p>
          ) : (
            emailAccountsList.map((item) => {
              const acc = item.account;
              return (
                <div key={`advanced-${item.id}`} className="email-account-card">
                  <div className="email-card-header">
                    <div className="email-card-title">
                      <h4>{acc.name || "Untitled Account"}</h4>
                    </div>
                  </div>
                  <div className="email-fields-grid">
                    <div className="form-group">
                      <label htmlFor={`email-smtp-host-${item.id}`}>
                        SMTP Host (Optional)
                      </label>
                      <input
                        id={`email-smtp-host-${item.id}`}
                        type="text"
                        className="input-field"
                        value={acc.smtpHost ?? ""}
                        onChange={(e) =>
                          handleEmailFieldChange(item.id, "smtpHost", e.target.value)
                        }
                        placeholder="Blank means derived host"
                      />
                    </div>

                    <div className="form-group">
                      <label htmlFor={`email-smtp-port-${item.id}`}>
                        SMTP Port (Optional)
                      </label>
                      <input
                        id={`email-smtp-port-${item.id}`}
                        type="number"
                        className="input-field"
                        value={acc.smtpPort ?? ""}
                        onChange={(e) =>
                          handleEmailFieldChange(
                            item.id,
                            "smtpPort",
                            e.target.value === "" ? "" : Number(e.target.value)
                          )
                        }
                        placeholder="Blank means 587 then 465"
                      />
                    </div>

                    <div className="form-group">
                      <label htmlFor={`email-smtp-security-${item.id}`}>
                        SMTP Security
                      </label>
                      <select
                        id={`email-smtp-security-${item.id}`}
                        className="input-field"
                        value={acc.smtpSecurity ?? "auto"}
                        onChange={(e) =>
                          handleEmailFieldChange(item.id, "smtpSecurity", e.target.value)
                        }
                      >
                        <option value="auto">Auto (STARTTLS then SSL)</option>
                        <option value="starttls">STARTTLS</option>
                        <option value="ssl">SSL (implicit TLS)</option>
                      </select>
                    </div>
                  </div>
                </div>
              );
            })
          )}
        </div>
      </AdvancedDisclosure>
    </div>
  );
}

export default EmailTab;
