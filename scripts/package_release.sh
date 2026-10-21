#!/usr/bin/env bash
# Builds a downloadable release: "build/Clearwise-Cleaner-<version>.dmg" (app + a link to /Applications) and its SHA-256.
# Usage: VERSION=1.0.0 scripts/package_release.sh
#
# Signed ad-hoc on purpose: an "Apple Development" certificate carries the developer's Apple ID email in the signature.
# Without a Developer ID (paid Apple Developer Program) the app is not notarized, so on first launch macOS asks to
# confirm opening it (see README → «Установка»).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-1.0.0}"
APP_NAME="Clearwise Cleaner"
APP="build/$APP_NAME.app"
DMG="build/Clearwise-Cleaner-$VERSION.dmg"
STAGE="build/dmg-stage"

echo "==> Building $APP_NAME $VERSION (ad-hoc signature)"
SIGN_IDENTITY=- VERSION="$VERSION" scripts/build_app.sh

echo "==> Checking the bundle carries nothing personal"
# grep -a, not strings: macOS strings skips the symbol table, where the debug map keeps source paths.
if grep -r -a -q -F -e "$HOME" -e "$(id -un)" "$APP"; then
    echo "error: the bundle contains the home folder or user name" >&2
    exit 1
fi
if codesign -dvv "$APP" 2>&1 | grep -q "^Authority="; then
    echo "error: the release must be signed ad-hoc (no certificate authority)" >&2
    exit 1
fi

echo "==> Assembling $DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"

(cd build && shasum -a 256 "$(basename "$DMG")") | tee "$DMG.sha256"
echo "==> Done: $ROOT/$DMG"
