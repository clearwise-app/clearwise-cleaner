#!/usr/bin/env bash
# Builds "build/Clearwise Cleaner.app" from a clean checkout: release binary, generated icon, Info.plist, ad-hoc signature.
# Usage: scripts/build_app.sh            (SCRATCH_PATH=.build-release scripts/build_app.sh to use another build dir)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCRATCH="${SCRATCH_PATH:-.build}"
APP_NAME="Clearwise Cleaner"
APP="build/$APP_NAME.app"
ICONSET="build/AppIcon.iconset"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

echo "==> Compiling (release)"
swift build -c release --product MacCleaner --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c release --product MacCleaner --scratch-path "$SCRATCH" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacCleaner" "$APP/Contents/MacOS/MacCleaner"

echo "==> Drawing icon"
mkdir -p build
swift scripts/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>            <string>app.clearwise.cleaner</string>
    <key>CFBundleName</key>                  <string>Clearwise</string>
    <key>CFBundleDisplayName</key>           <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>            <string>MacCleaner</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>    <string>${VERSION}</string>
    <key>CFBundleVersion</key>               <string>${BUILD_NUMBER}</string>
    <key>CFBundleDevelopmentRegion</key>     <string>ru</string>
    <key>LSMinimumSystemVersion</key>        <string>15.0</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSAppleEventsUsageDescription</key>
    <string>${APP_NAME} закрывает удаляемое приложение перед удалением.</string>
    <!-- Lets users drop an .app onto the Dock icon to open it in the uninstaller. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>      <string>Application</string>
            <key>CFBundleTypeRole</key>      <string>Viewer</string>
            <key>LSHandlerRank</key>         <string>None</string>
            <key>LSItemContentTypes</key>
            <array><string>com.apple.application-bundle</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing (hardened runtime)"
# Hardened Runtime blocks dylib injection into an app that holds Full Disk Access.
# Apple Events entitlement: NSRunningApplication.terminate() asks apps to quit before uninstalling.
# SIGN_IDENTITY="Developer ID Application: …" scripts/build_app.sh for a distributable, notarizable build
# (then: xcrun notarytool submit "build/Clearwise Cleaner.zip" --wait && xcrun stapler staple "build/Clearwise Cleaner.app").
ENTITLEMENTS="build/MacCleaner.entitlements"
cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
ENT
# Default: the first "Apple Development" certificate in the keychain, else ad-hoc. A real certificate keeps the
# Full Disk Access grant across rebuilds (macOS ties it to the signature; an ad-hoc one changes with every build).
DEFAULT_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
IDENTITY="${SIGN_IDENTITY:-${DEFAULT_IDENTITY:--}}"
echo "    identity: $IDENTITY"
# A secure timestamp is only needed (and only fetched) for Developer ID builds that go to notarization.
TIMESTAMP=$([[ "$IDENTITY" == "Developer ID"* ]] && echo "--timestamp" || echo "--timestamp=none")
codesign --force --options runtime $TIMESTAMP --entitlements "$ENTITLEMENTS" -s "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "==> Done: $ROOT/$APP"
