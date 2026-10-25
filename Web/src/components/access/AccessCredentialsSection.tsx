// Rune Weaver Dashboard — Credentials section of the declarative security policy
// surface for policy.toml.

import { useMemo, useState } from "react";
import {
  bindingAttention,
  bindingHostsSummary,
  bindingScopeSummary,
} from "../../policyBindingValidation";
import Modal from "../Modal";
import {
  PolicyBindingModal,
  type PolicyBindingDraft as PolicyBindingModalDraft,
} from "../PolicyBindingModal";
import { StoreSecretModal } from "../StoreSecretModal";
import { CloseIcon, TrashIcon } from "../icons";

// Binding modal state owned by the surface: null stays closed, otherwise add
// starts empty (with an optional prefilled key for the unlinked link path)
// while edit prefills from the live draft key.
export interface PolicyBindingModalState {
  mode: "add" | "edit";
  editingKey: string | null;
  initialKey?: string | null;
}

// Prefill for edit mode, read from the live draft so the modal conjunction
// matches the row that opened it.
export interface PolicyBindingEditingBinding {
  key: string;
  hosts: string[];
  methods: string[];
  pathPrefixes: string[];
}

// One stored credential binding as the draft carries it. The secret value
// itself never lives here: the binding names hosts, methods, and path prefixes
// while the value stays in the Keychain.
export interface PolicyBindingDraft {
  allowed_hosts: string[];
  allowed_methods: string[];
  allowed_path_prefixes: string[];
}

export interface CredentialsListProps {
  bindings?: Record<string, PolicyBindingDraft>;
  secretStatus?: Record<string, boolean>;
  allowedDomains?: string[];
  onAdd?: () => void;
  onEdit?: (key: string) => void;
  onDeleteRequest?: (key: string) => void;
  onSetSecret?: (key: string) => void;
  onDeleteSecretRequest?: (key: string) => void;
}

// Searchable credentials list. Rows stay compact so dozens scan without scrolling fatigue: key
// headline, Keychain presence, host and scope summaries, and a single attention dot.
export function CredentialsList({
  bindings = {},
  secretStatus = {},
  allowedDomains = [],
  onAdd,
  onEdit,
  onDeleteRequest,
  onSetSecret,
  onDeleteSecretRequest,
}: CredentialsListProps) {
  const [query, setQuery] = useState<string>("");
  const [attentionOnly, setAttentionOnly] = useState<boolean>(false);
  const handleOpenSecret = onSetSecret;
  const handleDeleteSecret = onDeleteSecretRequest;

  // Sorted entries keep the list deterministic across saves; attention and
  // summaries derive per render so a network edit immediately re-badges every
  // row without a second probe.
  const entries = useMemo(
    () => Object.entries(bindings ?? {}).sort(([a], [b]) => a.localeCompare(b)),
    [bindings],
  );

  const enriched = useMemo(
    () =>
      entries.map(([key, binding]) => {
        const hosts = binding?.allowed_hosts ?? [];
        const attention = bindingAttention(key, binding, allowedDomains ?? []);
        return {
          key,
          binding,
          hosts,
          attention,
          hostsSummary: bindingHostsSummary(hosts),
          scopeSummary: bindingScopeSummary(binding),
          stored: (secretStatus ?? {})[key] === true,
        };
      }),
    [entries, allowedDomains, secretStatus],
  );

  const normalizedQuery = query.trim().toLowerCase();
  const filtered = useMemo(() => {
    let rows = enriched;
    if (normalizedQuery) {
      rows = rows.filter(
        (row) =>
          row.key.toLowerCase().includes(normalizedQuery) ||
          (row.hosts ?? []).some((host) =>
            (host ?? "").toLowerCase().includes(normalizedQuery),
          ),
      );
    }
    if (attentionOnly) {
      rows = rows.filter((row) => row.attention.needsAttention);
    }
    return rows;
  }, [enriched, normalizedQuery, attentionOnly]);

  // Empty policy reads as an invitation, not a blank table: one sentence
  // explains the Keychain pairing before offering the add path.
  if (entries.length === 0) {
    return (
      <div data-testid="credentials-list">
        <div
          className="row mb-2"
          data-testid="credentials-list-header"
        >
          <span className="muted text-sm" data-testid="credentials-count">
            0 bindings
          </span>
          <span className="credentials-spacer" />
          <button type="button" className="ghost btn-sm" data-testid="credentials-add" onClick={() => onAdd?.()}>
            Add binding
          </button>
        </div>
        <div
          data-testid="credentials-empty"
          className="credentials-empty-box"
        >
          <p className="muted m-0 mb-1">
            No credential bindings yet.
          </p>
          <p className="muted m-0 mb-2">
            Add a binding, then set its secret value here. Type MY_KEY to store Keychain account MY_KEY used as rwsecret:MY_KEY; pasting rwsecret:MY_KEY stores the same slot. Values take effect on the next request with no restart.
          </p>
          <button
            type="button"
            className="ghost btn-sm"
            data-testid="credentials-empty-add"
            onClick={() => onAdd?.()}
          >
            Add binding
          </button>
        </div>
      </div>
    );
  }

  return (
    <div data-testid="credentials-list">
      <div
        className="row mb-2 credentials-list-header-wrap"
        data-testid="credentials-list-header"
      >
        <span className="muted text-sm" data-testid="credentials-count">
          {filtered.length === entries.length
            ? `${entries.length} ${entries.length === 1 ? "binding" : "bindings"}`
            : `${filtered.length} of ${entries.length} bindings`}
        </span>
        <input
          type="text"
          className="input-field credentials-search-input"
          aria-label="Search bindings"
          placeholder="Search by key or host…"
          data-testid="credentials-search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          autoComplete="off"
          spellCheck={false}
        />
        <label className="checkbox-row credentials-attention-label">
          <input
            type="checkbox"
            data-testid="credentials-attention-toggle"
            aria-label="Needs attention only"
            checked={attentionOnly}
            onChange={(event) => setAttentionOnly(event.target.checked)}
          />
          <span>Needs attention</span>
        </label>
        <span className="credentials-spacer" />
        <button type="button" className="ghost btn-sm" data-testid="credentials-add" onClick={() => onAdd?.()}>
          Add binding
        </button>
      </div>
      {filtered.length === 0 ? (
        <div data-testid="credentials-no-match" className="muted text-sm credentials-no-match">
          No bindings match this filter.{" "}
          <button
            type="button"
            className="ghost btn-sm"
            onClick={() => {
              setQuery("");
              setAttentionOnly(false);
            }}
          >
            Clear search
          </button>
        </div>
      ) : (
        <ul className="credentials-plain-list" aria-label="Credential bindings">
          {filtered.map((row) => (
            <li
              key={row.key}
              data-testid="credential-row"
              data-key={row.key}
              className="credential-row"
            >
              <div className="row">
              <button
                type="button"
                data-testid={`edit-binding-${row.key}`}
                aria-label={`Edit ${row.key}`}
                onClick={() => onEdit?.(row.key)}
                title={row.attention.needsAttention ? row.attention.reasons.join(" ") : `Edit ${row.key}`}
                className="credential-row-button"
              >
                {row.attention.needsAttention ? (
                  <span
                    data-testid="binding-attention"
                    aria-label="Needs attention"
                    title={row.attention.reasons.join(" ")}
                    className="credential-attention-dot"
                  >
                    ●
                  </span>
                ) : null}
                <code className="credential-key-code">{row.key}</code>
                <span
                  data-testid="keychain-badge"
                  className="status-pill credential-keychain-badge"
                >
                  {row.stored ? "Keychain Stored" : "Keychain Missing"}
                </span>
                <span
                  data-testid="binding-hosts-summary"
                  className="muted credential-hosts-summary"
                >
                  {row.hostsSummary}
                </span>
                <span data-testid="binding-scope-summary" className="muted credential-scope-summary">
                  {row.scopeSummary}
                </span>
              </button>
              {row.stored ? (
                <>
                  <button
                    type="button"
                    className="ghost btn-sm"
                    data-testid={`update-secret-${row.key}`}
                    aria-label={`Update secret for ${row.key}`}
                    onClick={(event) => {
                      event.stopPropagation();
                      handleOpenSecret?.(row.key);
                    }}
                    title={`Update secret for ${row.key}`}
                  >
                    Update
                  </button>
                  <button
                    type="button"
                    className="ghost btn-sm"
                    data-testid={`delete-secret-${row.key}`}
                    aria-label={`Delete secret for ${row.key}`}
                    onClick={(event) => {
                      event.stopPropagation();
                      handleDeleteSecret?.(row.key);
                    }}
                    title={`Delete secret for ${row.key}`}
                  >
                    Delete secret
                  </button>
                </>
              ) : (
                <button
                  type="button"
                  className="ghost btn-sm"
                  data-testid={`set-secret-${row.key}`}
                  aria-label={`Set secret for ${row.key}`}
                  onClick={(event) => {
                    event.stopPropagation();
                    handleOpenSecret?.(row.key);
                  }}
                  title={`Set secret for ${row.key}`}
                >
                  Set secret
                </button>
              )}
              <button
                type="button"
                className="icon-button"
                aria-label={`Delete ${row.key}`}
                data-testid={`delete-binding-${row.key}`}
                onClick={(event) => {
                  event.stopPropagation();
                  onDeleteRequest?.(row.key);
                }}
                title={`Delete ${row.key}`}
              >
                <TrashIcon size={14} />
              </button>
              </div>
              {row.attention.needsAttention ? (
                <div
                  data-testid="binding-attention-reason"
                  className="muted text-sm credential-attention-reason"
                >
                  {row.attention.reasons.join(" ")}
                </div>
              ) : null}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export interface AccessCredentialsSectionProps {
  bindings?: Record<string, PolicyBindingDraft>;
  secretStatus?: Record<string, boolean>;
  allowedDomains?: string[];
  // Keys from the Keychain enumeration without a draft binding, derived by the
  // surface so a rename re-sorts without a refetch.
  unlinkedKeys?: string[];
  listedLoaded?: boolean;
  listedError?: boolean;
  onAdd?: () => void;
  onEdit?: (key: string) => void;
  onDeleteRequest?: (key: string) => void;
  onSetSecret?: (key: string) => void;
  onDeleteSecretRequest?: (key: string) => void;
  onLinkUnlinkedSecret?: (key: string) => void;
  // Whether this section is the visible policy sub-tab.
  active: boolean;
  bindingModal: PolicyBindingModalState | null;
  editingBinding: PolicyBindingEditingBinding | null;
  bindingKeys: string[];
  modalSecretStatus?: Record<string, boolean>;
  onBindingModalSave: (draft: PolicyBindingModalDraft) => void;
  onBindingModalClose: () => void;
  onAddAllowedDomains: (domains: string[]) => void;
  isStoreOpen: boolean;
  secretModal: { key: string; isUpdate: boolean } | null;
  onSecretModalClose: () => void;
  onSecretModalSuccess: (key: string) => void;
  pendingDeleteKey: string | null;
  deleteAlsoSecret: boolean;
  onDeleteAlsoSecretChange: (checked: boolean) => void;
  onCancelDeleteBinding: () => void;
  onConfirmDeleteBinding: () => void;
  pendingDeleteSecretKey: string | null;
  onCancelDeleteSecret: () => void;
  onConfirmDeleteSecret: () => void;
}

// Credentials sub-tab of the policy surface: the bound-credential rows plus the
// unlinked Keychain secrets, with every confirmation and entry modal riding
// along so the section owns the whole credentials half of the editor.
export function AccessCredentialsSection({
  bindings = {},
  secretStatus = {},
  allowedDomains = [],
  unlinkedKeys = [],
  listedLoaded = false,
  listedError = false,
  onAdd,
  onEdit,
  onDeleteRequest,
  onSetSecret,
  onDeleteSecretRequest,
  onLinkUnlinkedSecret,
  active,
  bindingModal,
  editingBinding,
  bindingKeys,
  modalSecretStatus = {},
  onBindingModalSave,
  onBindingModalClose,
  onAddAllowedDomains,
  isStoreOpen,
  secretModal,
  onSecretModalClose,
  onSecretModalSuccess,
  pendingDeleteKey,
  deleteAlsoSecret,
  onDeleteAlsoSecretChange,
  onCancelDeleteBinding,
  onConfirmDeleteBinding,
  pendingDeleteSecretKey,
  onCancelDeleteSecret,
  onConfirmDeleteSecret,
}: AccessCredentialsSectionProps) {
  return (
    <>
      {active ? (
        <div id="policy-panel-credentials" role="tabpanel">
          <section
            aria-label="Credentials"
            data-testid="policy-credentials-section"
            className="credentials-section-spaced"
          >
            <h4>Target-bound credentials</h4>
            <p className="settings-section-hint">
              One binding pairs one key with hosts, methods, and path prefixes. The secret is
              sent only when host, method, and effective path all match. Prefixes apply to every
              host in the same binding. Empty hosts means the credential can never be sent; empty
              methods or prefixes mean Any.
            </p>
            <CredentialsList
              bindings={bindings}
              secretStatus={secretStatus}
              allowedDomains={allowedDomains}
              onAdd={onAdd}
              onEdit={onEdit}
              onDeleteRequest={onDeleteRequest}
              onSetSecret={onSetSecret}
              onDeleteSecretRequest={onDeleteSecretRequest}
            />
          </section>

          <section
            aria-label="Unlinked Keychain secrets"
            data-testid="unlinked-secrets"
            className="credentials-section-spaced"
          >
            <h4>Unlinked Keychain secrets</h4>
            <p className="settings-section-hint">
              Provider and email secrets also appear here because the Keychain service is shared.
            </p>
            {unlinkedKeys.length === 0 ? (
              listedLoaded && !listedError ? (
                <p className="muted text-sm" data-testid="unlinked-secrets-empty">
                  All Keychain secrets are linked to a binding.
                </p>
              ) : !listedLoaded ? (
                <p className="muted text-sm" data-testid="unlinked-secrets-loading">
                  Loading Keychain secrets…
                </p>
              ) : null
            ) : (
              <ul className="credentials-plain-list" aria-label="Unlinked secrets">
                {unlinkedKeys.map((key) => (
                  <li
                    key={key}
                    data-testid="unlinked-secret-row"
                    data-key={key}
                    className="unlinked-secret-row"
                  >
                    <code className="unlinked-secret-key">{key}</code>
                    <span
                      data-testid={`unlinked-stored-${key}`}
                      className="status-pill credential-keychain-badge"
                    >
                      Stored
                    </span>
                    <button
                      type="button"
                      className="ghost btn-sm"
                      data-testid={`link-unlinked-${key}`}
                      aria-label={`Link ${key}`}
                      onClick={() => onLinkUnlinkedSecret?.(key)}
                    >
                      Link
                    </button>
                    <button
                      type="button"
                      className="ghost btn-sm"
                      data-testid={`delete-unlinked-${key}`}
                      aria-label={`Delete secret for ${key}`}
                      onClick={() => onDeleteSecretRequest?.(key)}
                    >
                      Delete
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </div>
      ) : null}

      {bindingModal ? (
        <PolicyBindingModal
          mode={bindingModal.mode}
          initialBinding={editingBinding ?? undefined}
          initialKey={bindingModal.initialKey ?? undefined}
          editingKey={bindingModal.editingKey}
          existingBindingKeys={bindingKeys}
          secretStatus={modalSecretStatus}
          allowedDomains={allowedDomains}
          onSave={onBindingModalSave}
          onClose={onBindingModalClose}
          onAddAllowedDomains={onAddAllowedDomains}
          onStoreInKeychain={onSetSecret}
          isStoreOpen={isStoreOpen}
        />
      ) : null}

      {secretModal ? (
        <StoreSecretModal
          isOpen={Boolean(secretModal)}
          secretKey={secretModal.key}
          title={
            secretModal.isUpdate
              ? `Update Secret for ${secretModal.key} in Keychain`
              : `Store Secret for ${secretModal.key} to Keychain`
          }
          isUpdate={secretModal.isUpdate}
          onClose={onSecretModalClose}
          onSuccess={(key) => onSecretModalSuccess(key)}
        />
      ) : null}

      {pendingDeleteKey ? (
        <Modal
          label="Confirm delete binding"
          onClose={onCancelDeleteBinding}
          containerClassName="modal-container session-delete-modal"
        >
          <div className="modal-header">
            <h3>Delete binding?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={onCancelDeleteBinding}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted m-0">
              This will remove the binding for &lsquo;{pendingDeleteKey}&rsquo;. The Keychain
              secret stays stored; only the policy binding is removed. This cannot be undone.
            </p>
            <label className="checkbox-row credentials-delete-option">
              <input
                type="checkbox"
                data-testid="delete-binding-also-secret"
                checked={deleteAlsoSecret}
                onChange={(event) => onDeleteAlsoSecretChange(event.target.checked)}
              />
              <span>
                Also delete the Keychain secret for &lsquo;{pendingDeleteKey}&rsquo;.
              </span>
            </label>
          </div>
          <div className="modal-footer">
            <button type="button" className="ghost" onClick={onCancelDeleteBinding}>
              Keep
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => onConfirmDeleteBinding()}
              aria-label={`Confirm delete ${pendingDeleteKey}`}
            >
              Delete
            </button>
          </div>
        </Modal>
      ) : null}

      {pendingDeleteSecretKey ? (
        <Modal
          label="Confirm delete secret"
          onClose={onCancelDeleteSecret}
          containerClassName="modal-container session-delete-modal"
          testId="confirm-delete-secret-modal"
        >
          <div className="modal-header">
            <h3>Are you sure?</h3>
            <button
              type="button"
              className="icon-button"
              onClick={onCancelDeleteSecret}
              aria-label="Close"
            >
              <CloseIcon size={16} />
            </button>
          </div>
          <div className="modal-body">
            <p className="muted m-0">
              This will delete the Keychain secret for &lsquo;{pendingDeleteSecretKey}&rsquo;.
              The policy binding stays; only the stored value is removed. This cannot be undone.
            </p>
          </div>
          <div className="modal-footer">
            <button type="button" className="ghost" onClick={onCancelDeleteSecret}>
              Keep
            </button>
            <button
              type="button"
              className="danger"
              data-testid="confirm-delete-secret"
              onClick={() => onConfirmDeleteSecret()}
              aria-label={`Confirm delete secret ${pendingDeleteSecretKey}`}
            >
              Delete secret
            </button>
          </div>
        </Modal>
      ) : null}
    </>
  );
}

export default AccessCredentialsSection;
