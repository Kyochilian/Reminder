#!/usr/bin/env bash

set -euo pipefail

APP_NAME="Reminder"
BUNDLE_ID="${BUNDLE_ID:-com.phantasma.Reminder}"
APP_VERSION="${APP_VERSION:-0.1.2}"
APP_BUILD="${APP_BUILD:-1}"
MIN_SYSTEM="${MIN_SYSTEM:-13.0}"
OUTPUT_DIR="${1:-dist}"
ICON_SOURCE="${ICON_SOURCE:-assets/icon_source.png}"
ICON_ICNS="${ICON_ICNS:-assets/AppIcon.icns}"
FONT_AWESOME="${FONT_AWESOME:-assets/fa-solid-900.ttf}"

swift build -c release >/dev/null
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN_PATH="${BIN_DIR}/${APP_NAME}"
APP_DIR="${OUTPUT_DIR}/${APP_NAME}.app"

if [[ ! -f "${BIN_PATH}" ]]; then
  echo "Release binary not found: ${BIN_PATH}" >&2
  exit 1
fi

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Build icon assets if missing, then copy into app bundle
if [[ ! -f "${ICON_ICNS}" && -f "${ICON_SOURCE}" ]]; then
  ./scripts/generate_icns.sh "${ICON_SOURCE}" "$(dirname "${ICON_ICNS}")" >/dev/null
fi
if [[ -f "${ICON_ICNS}" ]]; then
  cp "${ICON_ICNS}" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi
if [[ -f "${FONT_AWESOME}" ]]; then
  cp "${FONT_AWESOME}" "${APP_DIR}/Contents/Resources/fa-solid-900.ttf"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh-Hans</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_SYSTEM}</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "${APP_DIR}" >/dev/null
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

echo "Packaged: ${APP_DIR}"
