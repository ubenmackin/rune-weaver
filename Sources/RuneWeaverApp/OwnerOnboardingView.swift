// Rune Weaver App — First-run owner-token onboarding sheet and Settings access section.
//
// Purpose: Lets the owner mint the single bearer token from the menu-bar app on
// first run, without opening Terminal, while keeping the secret visible exactly
// once and adopting it through a controlled restart.
// Scope: Two SwiftUI surfaces sharing one once-only secret view — the first-run
// sheet shown when boot finds no stored token, and the Settings access section
// for later status checks plus rotation. Minting itself delegates to the menu
// model, which routes through ServerAuth and ServerAuthTokenStore so randomness
// plus Keychain/0600-file persistence stay single-sourced.
// Architectural role: Keeps the menu-bar service loopback-usable before a token
// exists, surfaces fingerprint-prefix-only status, and guarantees the raw secret
// never reaches logs, URLs, or any store besides the auth persistence.

import AppKit
import SwiftUI

/// First-run sheet shown when boot resolves no owner token.
///
/// Generation delegates to the menu model — which mints through `ServerAuth`
/// rotation over `ServerAuthTokenStore`, reusing the shared CSPRNG plus
/// Keychain/0600-file persistence rather than reimplementing either — so this
/// view only presents the once-only value and gates the adopting restart behind
/// an explicit saved-it acknowledgement.
struct OwnerOnboardingView: View {
    /// Live menu-bar model owning the onboarding flag plus the once-only value.
    @Bindable var model: AppModel
    /// Local confirmation that the owner captured the secret; kept in the view
    /// so a sheet dismissal cannot be mistaken for a saved acknowledgement.
    @State private var acknowledgedSaved = false
    /// Transient copy feedback that never carries the secret itself.
    @State private var didCopy = false

    /// Creates the onboarding sheet.
    /// - Parameter model: Menu-bar model driving generation and restart.
    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up Owner Access")
                .font(.headline)
            Text("This Mac can already work locally. Generate an owner token to unlock LAN access from your other devices.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let onceToken = model.generatedOnceToken {
                OwnerOnceTokenView(
                    onceToken: onceToken,
                    fingerprint: model.ownerTokenFingerprint,
                    didCopy: $didCopy,
                    acknowledgedSaved: $acknowledgedSaved,
                    isRestarting: model.isRestarting,
                    onCopy: { copyOnceToken(onceToken) },
                    onAcknowledge: {
                        // Clearing plus restart live in the model so the secret
                        // leaves memory in the same hop that adopts the stored
                        // credential; the view only forwards the owner's word
                        // that the copy is safe to drop.
                        acknowledgedSaved = false
                        didCopy = false
                        model.acknowledgeGeneratedToken()
                    }
                )
            } else {
                Text("No owner token is stored yet. Loopback keeps working; LAN binds stay refused until you generate one.")
                    .font(.callout)
                if model.isGeneratingOwnerToken {
                    ProgressView("Generating…")
                } else if model.isRestarting {
                    // The adopting restart holds the boot flag across the hop,
                    // so generation stays hidden until the relaunch settles
                    // instead of minting a competing credential mid-restart.
                    ProgressView("Restarting…")
                } else {
                    Button("Generate Owner Token") {
                        acknowledgedSaved = false
                        didCopy = false
                        model.generateOwnerToken()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }

            if let tokenError = model.ownerTokenError {
                // Failures read as next steps (for example naming the
                // environment override that would shadow a replacement) so the
                // owner can recover without dropping to a shell.
                Text(tokenError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    /// Copies the once-only value to the clipboard without logging it.
    ///
    /// The pasteboard is the only copy outside the auth store; nothing here
    /// writes the secret to disk or the console.
    /// - Parameter token: Once-only value currently displayed.
    private func copyOnceToken(_ token: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(token, forType: .string)
        didCopy = true
    }
}

/// Settings access section for token status plus rotation without Terminal.
///
/// Status renders the non-secret fingerprint prefix and source label only, so
/// support comparisons never need the credential itself. Generate and Rotate
/// both route to the same `ServerAuthTokenStore`-backed mint in the menu model,
/// keeping the stored-value precedence identical to the terminal flow.
struct OwnerTokenSettingsSection: View {
    /// Live menu-bar model owning fingerprint, source, and mint entry points.
    @Bindable var model: AppModel
    /// Local saved-it confirmation scoped to this section's once-only display.
    @State private var acknowledgedSaved = false
    /// Transient copy feedback scoped to this section.
    @State private var didCopy = false

    /// Creates the settings section.
    /// - Parameter model: Menu-bar model driving status plus minting.
    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Owner Access")
                .font(.headline)

            if let fingerprint = model.ownerTokenFingerprint {
                // Fingerprint prefix only: enough to identify the active
                // credential for support, infeasible to recover it from.
                Text("Status: configured")
                    .font(.callout)
                Text("fingerprint: \(fingerprint) (SHA-256 prefix, non-secret)")
                    .font(.callout)
                    .textSelection(.enabled)
                if let source = model.ownerTokenSourceLabel {
                    Text("source: \(source)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if model.isGeneratingOwnerToken {
                    ProgressView("Rotating…")
                } else if model.isRestarting {
                    // Same single-flight as onboarding: the adopting restart is
                    // the only writer until boot settles, so Rotate stays
                    // hidden instead of minting mid-restart.
                    ProgressView("Restarting…")
                } else {
                    Button("Rotate Owner Token") {
                        acknowledgedSaved = false
                        didCopy = false
                        model.rotateOwnerToken()
                    }
                    .disabled(model.isRestarting)
                }
            } else {
                Text("Status: not configured — LAN binds are refused until a token exists.")
                    .font(.callout)
                if model.isGeneratingOwnerToken {
                    ProgressView("Generating…")
                } else if model.isRestarting {
                    ProgressView("Restarting…")
                } else {
                    Button("Generate Owner Token") {
                        acknowledgedSaved = false
                        didCopy = false
                        model.generateOwnerToken()
                    }
                }
            }

            if let onceToken = model.generatedOnceToken {
                Divider()
                OwnerOnceTokenView(
                    onceToken: onceToken,
                    fingerprint: model.ownerTokenFingerprint,
                    didCopy: $didCopy,
                    acknowledgedSaved: $acknowledgedSaved,
                    isRestarting: model.isRestarting,
                    onCopy: { copyOnceToken(onceToken) },
                    onAcknowledge: {
                        acknowledgedSaved = false
                        didCopy = false
                        model.acknowledgeGeneratedToken()
                    }
                )
            }

            if let tokenError = model.ownerTokenError {
                Text(tokenError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Button("Refresh Status") {
                model.refreshOwnerTokenStatus()
            }
            .font(.callout)
        }
        .onAppear {
            // Status is cheap and credential-free, so the section reconciles
            // with the store every time it appears instead of trusting a stale
            // boot-time snapshot.
            model.refreshOwnerTokenStatus()
        }
    }

    /// Copies the once-only replacement without retaining or logging it.
    /// - Parameter token: Once-only value currently displayed.
    private func copyOnceToken(_ token: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(token, forType: .string)
        didCopy = true
    }
}

/// Once-only secret presentation shared by onboarding and Settings.
///
/// Shown in monospace with an explicit Copy action, a lose-means-rotate
/// warning, and a saved-it gate before the adopting restart, so the secret's
/// single display cannot drift into a persistent or logged copy.
private struct OwnerOnceTokenView: View {
    /// Once-only secret held in memory by the menu model, never persisted here.
    let onceToken: String
    /// Non-secret prefix identifying the minted value for later comparison.
    let fingerprint: String?
    /// Whether the copy action confirmed, shown without echoing the secret.
    @Binding var didCopy: Bool
    /// Owner's word that the secret is stored elsewhere; gates the restart.
    @Binding var acknowledgedSaved: Bool
    /// Whether the adopting restart is in flight, disabling the acknowledgement
    /// action so concurrent confirmations collapse to one shutdown+boot.
    let isRestarting: Bool
    /// Copies the displayed value to the clipboard.
    let onCopy: () -> Void
    /// Clears the in-memory value and restarts the service to adopt it.
    let onAcknowledge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shown once — copy it now:")
                .font(.callout)
                .bold()
            Text(onceToken)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
            HStack {
                Button(didCopy ? "Copied" : "Copy") {
                    onCopy()
                }
                .keyboardShortcut("c", modifiers: .command)
                if let fingerprint {
                    Text("fingerprint: \(fingerprint)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            // A refresh or a lost copy has exactly one recovery — rotate again
            // from Settings — because the secret is never retained for re-show.
            Text(
                "If you lose this value or refresh before copying, it cannot be shown again. "
                    + "Copy it now, then acknowledge below; a replacement comes from Rotate in Settings."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Toggle("I saved it somewhere safe", isOn: $acknowledgedSaved)
                .toggleStyle(.checkbox)
            if isRestarting {
                ProgressView("Restarting…")
            } else {
                Button("I Saved It — Restart Service to Adopt Token") {
                    onAcknowledge()
                }
                .disabled(!acknowledgedSaved || isRestarting)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
