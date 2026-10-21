#!/usr/bin/env bash
# Builds build/MacCleaner.app from a clean checkout: release binary, generated icon, Info.plist, ad-hoc signature.
# Usage: scripts/build_app.sh            (SCRATCH_PATH=.build-release scripts/build_app.sh to use another build dir)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCRATCH="${SCRATCH_PATH:-.build}"
APP="build/MacCleaner.app"
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
    <key>CFBundleName</key>                  <string>MacCleaner</string>
    <key>CFBundleDisplayName</key>           <string>MacCleaner</string>
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
    <string>MacCleaner закрывает удаляемое приложение перед удалением.</string>
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

echo "==> Signing (ad-hoc)"
codesign --force --deep -s - "$APP"
codesign --verify --deep "$APP"

echo "==> Done: $ROOT/$APP"
