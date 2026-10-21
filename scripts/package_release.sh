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
SIGN_IDENTITY=- UNIVERSAL=1 VERSION="$VERSION" scripts/build_app.sh

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
# A designed window (background with an arrow to Applications) needs dmgbuild, which writes Finder's
# .DS_Store without scripting Finder: python3 -m venv build/.venv && build/.venv/bin/pip install dmgbuild
DMGBUILD="${DMGBUILD:-build/.venv/bin/dmgbuild}"
if [[ -x "$DMGBUILD" ]]; then
    ART="build/dmg-art"
    mkdir -p "$ART"
    swift scripts/make_art.swift dmg "$ART/background.png" 1
    swift scripts/make_art.swift dmg "$ART/background@2x.png" 2
    tiffutil -cathidpicheck "$ART/background.png" "$ART/background@2x.png" -out "$ART/background.tiff" 2>/dev/null
    "$DMGBUILD" -s scripts/dmg_settings.py -D app="$APP" -D background="$ART/background.tiff" "$APP_NAME" "$DMG" >/dev/null
    rm -rf "$ART"
else
    echo "    dmgbuild not found: plain window (see the comment above)"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/$APP_NAME.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
    rm -rf "$STAGE"
fi
# Nothing personal may ride along in the DMG either (Finder's .DS_Store keeps alias records).
MNT="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
LEAK=0
grep -r -a -q -F -e "$HOME" -e "$(id -un)" "$MNT" && LEAK=1
hdiutil detach "$MNT" >/dev/null
if [[ $LEAK == 1 ]]; then
    echo "error: the DMG contains the home folder or user name" >&2
    exit 1
fi

(cd build && shasum -a 256 "$(basename "$DMG")") | tee "$DMG.sha256"
echo "==> Done: $ROOT/$DMG"
