#!/usr/bin/env bash
set -euo pipefail

# Rune Weaver — Build Standalone macOS App Bundle (.app)
# Packages the Swift engine, menu bar UI, and compiled React dashboard into a self-contained macOS agent bundle.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

# App version (single source: VERSION file, else git tag, else fallback
# matching the CLI/api version so Info.plist cannot drift silently).
APP_VERSION=""
if [ -f "${ROOT_DIR}/VERSION" ]; then
    APP_VERSION="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION" | sed 's/^v//')"
fi
if [ -z "${APP_VERSION}" ]; then
    APP_VERSION="$(git -C "${ROOT_DIR}" describe --tags --dirty 2>/dev/null | sed 's/^v//' || true)"
fi
if [ -z "${APP_VERSION}" ]; then
    APP_VERSION="0.1.0"
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
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSUserNotificationAlertStyle</key>
    <string>banner</string>
</dict>
</plist>
PLIST_EOF

# Code sign ad-hoc
echo "==> Ad-hoc signing ${APP_NAME}..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Successfully built: ${APP_BUNDLE}"
