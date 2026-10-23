#!/usr/bin/env bash
# Builds a downloadable release: "build/Clearwise-Cleaner-<version>.dmg" (app + a link to /Applications) and its SHA-256.
# Usage: VERSION=1.0.0 scripts/package_release.sh                          (ad-hoc, not notarized)
#        SIGN_IDENTITY="Developer ID Application: … (TEAMID)" VERSION=1.0.0 scripts/package_release.sh
#                                                                          (signed, notarized, stapled — docs/SIGNING.md)
#
# Without SIGN_IDENTITY the release is signed ad-hoc on purpose: an "Apple Development" certificate carries the
# developer's Apple ID email in the signature, and without a Developer ID (paid Apple Developer Program) the app
# cannot be notarized, so on first launch macOS asks to confirm opening it (see README → «Установка»).
# With a Developer ID the app and the DMG are signed with it, the DMG goes to Apple's notary service and the
# ticket is stapled to it. Credentials never live in the repository: notarytool reads them from the keychain
# profile NOTARY_PROFILE (default clearwise-notary), saved once with `xcrun notarytool store-credentials`.
# NOTARIZE=0 skips notarization (a signed DMG to check the signature first).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-1.0.0}"
APP_NAME="Clearwise Cleaner"
APP="build/$APP_NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-clearwise-notary}"
DMG="build/Clearwise-Cleaner-$VERSION.dmg"
STAGE="build/dmg-stage"

if [[ "$SIGN_IDENTITY" == - ]]; then
    MODE=ad-hoc
elif [[ "$SIGN_IDENTITY" == "Developer ID Application: "* || "$SIGN_IDENTITY" =~ ^[0-9A-F]{40}$ ]]; then
    MODE=developer-id
else
    echo "error: SIGN_IDENTITY must be - (ad-hoc) or a \"Developer ID Application: …\" certificate (name or SHA-1)" >&2
    exit 1
fi

if [[ $MODE == developer-id ]]; then
    # Fail before a five-minute universal build, not after it.
    if ! security find-identity -v -p codesigning | grep -q -F "$SIGN_IDENTITY"; then
        echo "error: no valid signing identity \"$SIGN_IDENTITY\" in the keychain (security find-identity -v -p codesigning)" >&2
        exit 1
    fi
    if [[ "${NOTARIZE:-1}" == 1 ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "error: notarytool cannot sign in with the keychain profile \"$NOTARY_PROFILE\" (docs/SIGNING.md, step 3)" >&2
        exit 1
    fi
fi

echo "==> Building $APP_NAME $VERSION ($MODE signature)"
SIGN_IDENTITY="$SIGN_IDENTITY" UNIVERSAL=1 VERSION="$VERSION" scripts/build_app.sh

echo "==> Checking the bundle carries nothing personal"
# grep -a, not strings: macOS strings skips the symbol table, where the debug map keeps source paths.
if grep -r -a -q -F -e "$HOME" -e "$(id -un)" "$APP"; then
    echo "error: the bundle contains the home folder or user name" >&2
    exit 1
fi
# A Developer ID signature names the developer and team, which is public anyway; an "Apple Development" one carries
# the Apple ID email and must never ship.
AUTHORITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ $MODE == ad-hoc && -n "$AUTHORITY" ]]; then
    echo "error: the release must be signed ad-hoc (no certificate authority)" >&2
    exit 1
fi
if [[ $MODE == developer-id && "$AUTHORITY" != "Developer ID Application: "* ]]; then
    echo "error: the app is signed by \"$AUTHORITY\", not a Developer ID Application certificate" >&2
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

if [[ $MODE == developer-id ]]; then
    echo "==> Signing $DMG"
    codesign --force --timestamp -s "$SIGN_IDENTITY" "$DMG"
    codesign --verify --strict "$DMG"

    if [[ "${NOTARIZE:-1}" == 1 ]]; then
        # The DMG is the outer container: Apple checks every binary inside it, and the ticket stapled to the DMG
        # lets Gatekeeper accept it offline. The app copied out of it is found by Gatekeeper online (same ticket).
        echo "==> Notarizing $DMG (usually a few minutes)"
        SUBMIT_LOG="build/notarytool-$VERSION.json"
        # The verdict is read from the JSON below, so a non-zero exit (rejected upload) still reaches Apple's log.
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json >"$SUBMIT_LOG" || true
        cat "$SUBMIT_LOG"; echo
        if ! grep -q '"status" *: *"Accepted"' "$SUBMIT_LOG"; then
            ID="$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' "$SUBMIT_LOG" | head -1)"
            echo "error: notarization was not accepted; Apple's report:" >&2
            [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2
            exit 1
        fi
        echo "==> Stapling the ticket"
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
        # What a downloaded copy will meet: Gatekeeper's verdict on the image and, inside it, on the app.
        spctl --assess --type open --context context:primary-signature -vv "$DMG"
        MNT="$(mktemp -d)"
        hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
        spctl --assess --type execute -vv "$MNT/$APP_NAME.app" || { hdiutil detach "$MNT" >/dev/null; exit 1; }
        hdiutil detach "$MNT" >/dev/null
    fi
fi

(cd build && shasum -a 256 "$(basename "$DMG")") | tee "$DMG.sha256"
echo "==> Done: $ROOT/$DMG"
