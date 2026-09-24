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
    <key>NSUserNotificationAlertStyle</key>
    <string>banner</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST_EOF

# Code signing: prefer explicit CODE_SIGN_IDENTITY, or search for an available codesigning identity.
# Stable identities preserve macOS Keychain ACLs across app rebuilds, whereas ad-hoc ("-") signatures
# change their CDHash with every compile, causing macOS to re-prompt for Keychain access.
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"

if [ -z "${SIGNING_IDENTITY}" ]; then
    # Look for Apple Development, Developer ID, or a local code signing certificate
    AVAILABLE_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -E 'Apple Development|Developer ID Application|RuneWeaver' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
    if [ -n "${AVAILABLE_IDENTITY}" ]; then
        SIGNING_IDENTITY="${AVAILABLE_IDENTITY}"
    fi
fi

if [ -n "${SIGNING_IDENTITY}" ]; then
    echo "==> Signing ${APP_NAME} with identity: ${SIGNING_IDENTITY}..."
    codesign --force --deep --sign "${SIGNING_IDENTITY}" "${APP_BUNDLE}"
else
    echo "==> Ad-hoc signing ${APP_NAME} (Note: set CODE_SIGN_IDENTITY or create a local signing cert to persist Keychain access across rebuilds)..."
    codesign --force --deep --sign - "${APP_BUNDLE}"
fi

echo "==> Successfully built: ${APP_BUNDLE}"
