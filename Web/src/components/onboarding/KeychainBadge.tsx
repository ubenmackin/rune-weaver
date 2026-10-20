// Rune Weaver Dashboard — Shared Keychain badge plus store action.
import { CheckIcon, KeyIcon } from "../icons";

export interface KeychainBadgeProps {
  isStored: boolean;
  keyEnv: string;
  onStore: () => void;
}

// Single badge copy keeps wizard and settings surfaces identical.
export function KeychainBadge({ isStored, keyEnv, onStore }: KeychainBadgeProps) {
  return (
    <div className="keychain-badge-group">
      {isStored ? (
        <span className="keychain-status-badge stored">
          <CheckIcon size={12} /> Stored in Keychain
        </span>
      ) : (
        <span className="keychain-status-badge missing">Not Set in Keychain</span>
      )}
      <button
        type="button"
        className="keychain-action-btn"
        onClick={onStore}
        title={isStored ? `Update secret for ${keyEnv}` : `Store secret for ${keyEnv} in Keychain`}
      >
        <KeyIcon size={12} />
        <span>{isStored ? "Update Key" : "Store Key"}</span>
      </button>
    </div>
  );
}

export default KeychainBadge;
