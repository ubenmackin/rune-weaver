#!/usr/bin/env bash
set -euo pipefail

# Rune Weaver — Build Standalone macOS App Bundle (.app)
# Packages the Swift engine, menu bar UI, and compiled React dashboard into a self-contained macOS agent bundle.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Single-source version: stamp the Swift constant from VERSION before building
# so the app binary embeds the same version stamped into Info.plist below.
# Covers direct script invocation without `make app` (which already depends on
# `version`); fails closed when VERSION is not X.Y.Z semver like `make version`.
echo "==> Stamping engine version from VERSION..."
make -C "${ROOT_DIR}" version

echo "==> Building Web Dashboard (Web/dist)..."
cd "${ROOT_DIR}/Web"
if [ ! -d "node_modules" ]; then
    if [ -f "package-lock.json" ]; then
        npm ci
    else
        npm install
    fi
fi
npm run build

echo "==> Building RuneWeaverApp in release mode..."
cd "${ROOT_DIR}"
swift build -c release --product RuneWeaverApp

# Find the built release executable
BIN_PATH="$(swift build -c release --product RuneWeaverApp --show-bin-path)/RuneWeaverApp"
if [ ! -f "${BIN_PATH}" ]; then
    echo "Error: Could not find built binary at ${BIN_PATH}" >&2
    exit 1
fi

APP_NAME="Rune Weaver.app"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Assembling ${APP_NAME} in ${DIST_DIR}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}/web"

# Copy executable
cp "${BIN_PATH}" "${MACOS_DIR}/RuneWeaverApp"
chmod +x "${MACOS_DIR}/RuneWeaverApp"

# Copy web assets (guarded: the npm build must have produced the bundle,
# otherwise the copy would silently stage an empty web directory).
if [ ! -f "${ROOT_DIR}/Web/dist/index.html" ]; then
    echo "Error: Web dashboard bundle missing at ${ROOT_DIR}/Web/dist/index.html (npm run build did not produce it)" >&2
    exit 1
fi
cp -R "${ROOT_DIR}/Web/dist/." "${RESOURCES_DIR}/web/"

# Copy app icon (generates if missing)
if [ ! -f "${ROOT_DIR}/Resources/AppIcon.icns" ]; then
    echo "==> Generating AppIcon.icns..."
    python3 "${ROOT_DIR}/scripts/generate_app_icon.py"
fi
if [ -f "${ROOT_DIR}/Resources/AppIcon.icns" ]; then
    cp "${ROOT_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# App version (single source: VERSION file, else git tag, else fail closed
# so Info.plist cannot drift on a hand-edited literal).
APP_VERSION=""
if [ -f "${ROOT_DIR}/VERSION" ]; then
    APP_VERSION="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION" | sed 's/^[vV]//')"
fi
if [ -z "${APP_VERSION}" ]; then
    APP_VERSION="$(git -C "${ROOT_DIR}" describe --tags --dirty 2>/dev/null | sed 's/^[vV]//' || true)"
fi
if [ -z "${APP_VERSION}" ]; then
    echo "Error: cannot determine app version (missing VERSION file and no git tag); refusing to stamp a hand-edited fallback." >&2
    exit 1
fi
# Fail closed on non-semver like `make version`: Info.plist must never carry
# a hand-edited or malformed string while the engine embeds the stamped X.Y.Z.
if ! printf '%s' "${APP_VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Error: APP_VERSION must be X.Y.Z semver (got '${APP_VERSION}')" >&2
    exit 1
fi

# Generate Info.plist
cat << PLIST_EOF > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleName</key>
    <string>Rune Weaver</string>
    <key>CFBundleDisplayName</key>
    <string>Rune Weaver</string>
    <key>CFBundleIdentifier</key>
    <string>com.runeweaver.app</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>RuneWeaverApp</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSContactsUsageDescription</key>
    <string>Rune Weaver uses your contacts to resolve recipient names to phone numbers or email addresses when you ask it to send a message.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Rune Weaver uses your calendars to index events and answer your questions about upcoming events when you enable calendar access.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>Rune Weaver uses your reminders to index tasks and answer your questions about to-dos when you enable reminders access.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Rune Weaver uses your calendars to index events and answer your questions about upcoming events when you enable calendar access.</string>
    <key>NSRemindersUsageDescription</key>
    <string>Rune Weaver uses your reminders to index tasks and answer your questions about to-dos when you enable reminders access.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Rune Weaver uses speech recognition to transcribe audio recordings, voice memos, and video audio tracks during local file indexing.</string>
    <key>NSUserNotificationAlertStyle</key>
    <string>banner</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Rune Weaver sends messages through Messages when you ask it to.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST_EOF

# Code signing lives behind sign_app_bundle so every build signs and verifies
# through one closed gate. A stable identity is mandatory because macOS binds
# Keychain ACLs and TCC grants (such as Full Disk Access) to the signature:
# every ad-hoc rebuild mints a fresh CDHash, so Keychain re-prompts and prior
# TCC approvals stop matching. Refusing silent ad-hoc fallback keeps a rebuild
# from looking signed while quietly losing its data protections.
# Over ssh the login keychain stays locked (no GUI unlock happened at login),
# so codesign cannot reach the private key even though the same command works
# from local Terminal.app where the keychain is already unlocked. Signing once
# at the top level without --deep avoids sealing nested content with stale
# hashes; the closing verify still walks the whole bundle strictly to fail closed.
sign_app_bundle() {
    local bundle_path="$1"

    # Strip quarantine and stale seals so the fresh signature starts clean.
    xattr -cr "${bundle_path}"

SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"

    # The sole ad-hoc path is an explicit opt-in: only CODE_SIGN_IDENTITY=-
    # signs ad-hoc directly. Anything else must resolve to a stable identity
    # or fail closed below — silent ad-hoc is refused because its CDHash churn
    # breaks Keychain ACLs and TCC grants like Full Disk Access on every rebuild.
    if [ "${SIGNING_IDENTITY}" = "-" ]; then
        echo "==> Ad-hoc signing ${APP_NAME} (explicit CODE_SIGN_IDENTITY=- only; Keychain ACLs and TCC will not persist across rebuilds)..."
        if ! codesign --force --sign - "${bundle_path}"; then
            echo "Error: ad-hoc codesign failed for ${bundle_path}." >&2
            echo "  List identities with: security find-identity -v -p codesigning" >&2
            echo "  A locked keychain hides keys: security unlock-keychain ~/Library/Keychains/login.keychain-db" >&2
            echo "  In Keychain Access, the private key's Access Control must grant codesign access or signing prompts and fails." >&2
            echo "  Ad-hoc is refused unless explicitly requested because every rebuild mints a new CDHash, which breaks Keychain ACLs and TCC grants like Full Disk Access." >&2
            exit 1
        fi
        if ! codesign --verify --deep --strict --verbose=2 "${bundle_path}"; then
            echo "Error: ad-hoc signature verification failed for ${bundle_path}." >&2
            echo "  List identities with: security find-identity -v -p codesigning" >&2
            echo "  A locked keychain hides keys: security unlock-keychain ~/Library/Keychains/login.keychain-db" >&2
            echo "  In Keychain Access, the private key's Access Control must grant codesign access or signing prompts and fails." >&2
            echo "  Ad-hoc is refused unless explicitly requested because every rebuild mints a new CDHash, which breaks Keychain ACLs and TCC grants like Full Disk Access." >&2
            exit 1
        fi
        return 0
    fi

    if [ -z "${SIGNING_IDENTITY}" ]; then
        # Look for Apple Development, Developer ID, or a local code signing certificate
        AVAILABLE_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -E 'Apple Development|Developer ID Application|RuneWeaver' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
        if [ -n "${AVAILABLE_IDENTITY}" ]; then
            SIGNING_IDENTITY="${AVAILABLE_IDENTITY}"
        fi
    fi

    if [ -z "${SIGNING_IDENTITY}" ]; then
        echo "Error: no codesigning identity found; refusing ad-hoc fallback." >&2
        echo "  List identities with: security find-identity -v -p codesigning" >&2
        echo "  A locked keychain hides keys: security unlock-keychain ~/Library/Keychains/login.keychain-db" >&2
        echo "  In Keychain Access, the private key's Access Control must grant codesign access or signing prompts and fails." >&2
        echo "  Ad-hoc is refused because every rebuild mints a new CDHash, which breaks Keychain ACLs and TCC grants like Full Disk Access." >&2
        if [ -n "${SSH_TTY:-}" ] || [ -n "${SSH_CONNECTION:-}" ]; then
            echo "  The login keychain is locked over ssh, so codesign cannot use the key even when it works from local Terminal.app." >&2
            echo "  Run security unlock-keychain ~/Library/Keychains/login.keychain-db first, then retry." >&2
            echo "  Or run make app from local Terminal.app instead of over ssh." >&2
            echo "  To persist approval: security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <pw> ~/Library/Keychains/login.keychain-db" >&2
        fi
        exit 1
    fi

    echo "==> Signing ${APP_NAME} with identity: ${SIGNING_IDENTITY}..."
    if ! codesign --force --sign "${SIGNING_IDENTITY}" "${bundle_path}"; then
        echo "Error: codesign failed for identity '${SIGNING_IDENTITY}'." >&2
        echo "  List identities with: security find-identity -v -p codesigning" >&2
        echo "  A locked keychain hides keys: security unlock-keychain ~/Library/Keychains/login.keychain-db" >&2
        echo "  In Keychain Access, the private key's Access Control must grant codesign access or signing prompts and fails." >&2
        echo "  Ad-hoc is refused because every rebuild mints a new CDHash, which breaks Keychain ACLs and TCC grants like Full Disk Access — no downgrade attempted." >&2
        if [ -n "${SSH_TTY:-}" ] || [ -n "${SSH_CONNECTION:-}" ]; then
            echo "  The login keychain is locked over ssh, so codesign cannot use the key even when it works from local Terminal.app." >&2
            echo "  Run security unlock-keychain ~/Library/Keychains/login.keychain-db first, then retry." >&2
            echo "  Or run make app from local Terminal.app instead of over ssh." >&2
            echo "  To persist approval: security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <pw> ~/Library/Keychains/login.keychain-db" >&2
        fi
        exit 1
    fi

    if ! codesign --verify --deep --strict --verbose=2 "${bundle_path}"; then
        echo "Error: signature verification failed for ${bundle_path}." >&2
        echo "  List identities with: security find-identity -v -p codesigning" >&2
        echo "  A locked keychain hides keys: security unlock-keychain ~/Library/Keychains/login.keychain-db" >&2
        echo "  In Keychain Access, the private key's Access Control must grant codesign access or signing prompts and fails." >&2
        echo "  Ad-hoc is refused because every rebuild mints a new CDHash, which breaks Keychain ACLs and TCC grants like Full Disk Access." >&2
        if [ -n "${SSH_TTY:-}" ] || [ -n "${SSH_CONNECTION:-}" ]; then
            echo "  The login keychain is locked over ssh, so codesign cannot use the key even when it works from local Terminal.app." >&2
            echo "  Run security unlock-keychain ~/Library/Keychains/login.keychain-db first, then retry." >&2
            echo "  Or run make app from local Terminal.app instead of over ssh." >&2
            echo "  To persist approval: security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <pw> ~/Library/Keychains/login.keychain-db" >&2
        fi
        exit 1
    fi
}

sign_app_bundle "${APP_BUNDLE}"

echo "==> Successfully built: ${APP_BUNDLE}"
