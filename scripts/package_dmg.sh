#!/usr/bin/env bash

set -euo pipefail

APP_NAME="Reminder"
APP_VERSION="${APP_VERSION:-0.1.1}"
APP_BUILD="${APP_BUILD:-1}"
OUTPUT_DIR="${1:-dist}"
VOLUME_NAME="${VOLUME_NAME:-${APP_NAME}}"
DMG_PATH="${OUTPUT_DIR}/${APP_NAME}-v${APP_VERSION}-macOS.dmg"
STAGING_DIR="$(mktemp -d "/tmp/${APP_NAME}.dmg.XXXXXX")"

cleanup() {
  rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

# Always build a fresh app bundle before wrapping it as a DMG.
APP_VERSION="${APP_VERSION}" APP_BUILD="${APP_BUILD}" ./scripts/package_app.sh "${OUTPUT_DIR}" >/dev/null

APP_DIR="${OUTPUT_DIR}/${APP_NAME}.app"
if [[ ! -d "${APP_DIR}" ]]; then
  echo "App bundle not found: ${APP_DIR}" >&2
  exit 1
fi

cp -R "${APP_DIR}" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"

rm -f "${DMG_PATH}"
hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}" >/dev/null

echo "Packaged: ${DMG_PATH}"
