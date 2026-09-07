#!/usr/bin/env bash
# Wraps a built OCRFlow.app in a compressed drag-to-Applications disk image.
#
# Usage:
#   Scripts/make-dmg.sh <path to OCRFlow.app> <output .dmg>
set -euo pipefail

APP="${1:?usage: make-dmg.sh <OCRFlow.app> <output.dmg>}"
DMG="${2:?usage: make-dmg.sh <OCRFlow.app> <output.dmg>}"

staging="$(mktemp -d)"
trap 'rm -rf "${staging}"' EXIT

# ditto, not cp: it is the copy that keeps a signed bundle's extended
# attributes intact, and a broken signature only shows up at install time.
ditto "${APP}" "${staging}/$(basename "${APP}")"
ln -s /Applications "${staging}/Applications"

rm -f "${DMG}"
hdiutil create -volname "OCRFlow" -srcfolder "${staging}" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -quiet "${DMG}"

echo "Wrote ${DMG} ($(du -h "${DMG}" | cut -f1))"
