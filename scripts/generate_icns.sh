#!/usr/bin/env bash

set -euo pipefail

SOURCE_IMG="${1:-}"
OUT_DIR="${2:-}"

if [[ -z "$SOURCE_IMG" || -z "$OUT_DIR" ]]; then
    echo "Usage: $0 <source_image> <output_directory>"
    exit 1
fi

ICONSET_DIR="${OUT_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"

echo "Generating iconset from ${SOURCE_IMG}..."


# Generate required sizes for macOS .icns (includes @2x variants)
sips -z 16 16     "${SOURCE_IMG}" --out "${ICONSET_DIR}/icon_16x16.png" --setProperty format png > /dev/null
sips -z 32 32     "${SOURCE_IMG}" --out "${ICONSET_DIR}/icon_16x16@2x.png" --setProperty format png > /dev/null
sips -z 32 32     "${SOURCE_IMG}" --out "${ICONSET_DIR}/icon_32x32.png" --setProperty format png > /dev/null
sips -z 64 64     "${SOURCE_IMG}" --out "${ICONSET_DIR}/icon_32x32@2x.png" --setProperty format png > /dev/null
sips -z 128 128   "${SOURCE_IMG}" --out "${ICONSET_DIR}/icon_128x128.png" --setProperty format png > /dev/null
sips -z 256 256   "${SOURCE_IMG}" --out "${ICONSET_DIR}/icon_128x128@2x.png" --setProperty format png > /dev/null
sips -z 256 256   "${SOURCE_IMG}" --out "${ICONSET_DIR}/icon_256x256.png" --setProperty format png > /dev/null
sips -z 512 512   "${SOURCE_IMG}" --out "${ICONSET_DIR}/icon_256x256@2x.png" --setProperty format png > /dev/null
sips -z 512 512   "${SOURCE_IMG}" --out "${ICONSET_DIR}/icon_512x512.png" --setProperty format png > /dev/null
sips -z 1024 1024 "${SOURCE_IMG}" --out "${ICONSET_DIR}/icon_512x512@2x.png" --setProperty format png > /dev/null


echo "Converting iconset to icns..."
iconutil -c icns "${ICONSET_DIR}" -o "${OUT_DIR}/AppIcon.icns"

echo "Done:"
echo "  ${OUT_DIR}/AppIcon.icns"
echo "  ${ICONSET_DIR}"
