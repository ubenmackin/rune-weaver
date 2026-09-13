#!/usr/bin/env bash
set -euo pipefail

# Rune Weaver — Build Distribution DMG
# Packages "Rune Weaver.app" and an "/Applications" symlink into a drag-and-drop DMG installer.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_NAME="Rune Weaver.app"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}"
DMG_NAME="Rune Weaver.dmg"
DMG_OUTPUT="${DIST_DIR}/${DMG_NAME}"
STAGING_DIR="${DIST_DIR}/dmg_staging"

# Ensure .app is built
if [ ! -d "${APP_BUNDLE}" ]; then
    echo "==> ${APP_NAME} not found. Building app first..."
    bash "${SCRIPT_DIR}/build_app.sh"
fi

echo "==> Preparing DMG staging in ${STAGING_DIR}..."
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

# Copy .app bundle into staging
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"

# Create Applications symlink for drag-and-drop install
ln -s /Applications "${STAGING_DIR}/Applications"

# Remove existing DMG if present
rm -f "${DMG_OUTPUT}"

echo "==> Creating ${DMG_NAME} using hdiutil..."
hdiutil create \
    -volname "Rune Weaver" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_OUTPUT}"

# Clean staging directory
rm -rf "${STAGING_DIR}"

echo "==> Successfully generated DMG: ${DMG_OUTPUT}"
