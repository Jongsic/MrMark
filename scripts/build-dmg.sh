#!/usr/bin/env bash
# Builds MrMark.app (Release) and packages it into a DMG under build/.
# The release workflow calls this same script, so a local run produces
# exactly what a GitHub release ships.
#
# Usage: scripts/build-dmg.sh [version]
#   version   label embedded in the DMG file name
#             (default: `git describe`, e.g. v0.1.0 or aabc14c-dirty)
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"

command -v xcodegen >/dev/null 2>&1 || {
  echo "error: xcodegen not found — brew install xcodegen" >&2
  exit 1
}

# Build inside Xcode's default DerivedData: Spotlight doesn't index it, so
# the built .app never shows up next to the installed one in ⌘Space. The
# repo-level build/ ends up holding only the .dmg.
(
  cd macos
  xcodegen generate
  xcodebuild \
    -scheme MrMark \
    -configuration Release \
    CODE_SIGN_IDENTITY=- \
    build
)

PRODUCTS_DIR=$(
  cd macos
  xcodebuild -scheme MrMark -configuration Release -showBuildSettings 2>/dev/null |
    awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}'
)
APP="${PRODUCTS_DIR}/MrMark.app"
STAGING="build/dmg-staging"
DMG="build/MrMark-${VERSION}.dmg"

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
cp LICENSE "$STAGING/LICENSE.txt"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "MrMark" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo
echo "→ $DMG"
