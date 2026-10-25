#!/bin/sh
set -eu

# Assemble Iris.app.
#   Scripts/build_app.sh          # debug (default)
#   Scripts/build_app.sh release  # optimized
# Env:
#   VERSION  CFBundleShortVersionString (default 0.1.0)
#   BUILD    CFBundleVersion (default 1)
#   ALLOW_WARNINGS=1  skip -warnings-as-errors (default: warnings are errors,
#                     matching CI's build-strict/test-strict gates)
#   SIGN_IDENTITY     codesign identity (default "-", ad-hoc); see below

CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in
    debug|release) ;;
    *)
        echo "usage: $0 [debug|release]" >&2
        exit 1
        ;;
esac

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
case "$VERSION" in
    *[!0-9.]*|*.*.*.*|*..*|.*|*.)
        echo "error: VERSION must be numeric dotted X.Y.Z, got \"$VERSION\"" >&2
        exit 1
        ;;
esac
case "$VERSION" in
    *.*.*) ;;
    *)
        echo "error: VERSION must be numeric dotted X.Y.Z, got \"$VERSION\"" >&2
        exit 1
        ;;
esac
case "$BUILD" in
    ''|*[!0-9]*|0)
        echo "error: BUILD must be a positive integer, got \"$BUILD\"" >&2
        exit 1
        ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TARGET_APP="$ROOT/Iris.app"
swift "$ROOT/Scripts/assert_app_stopped.swift" "$TARGET_APP"
if [ "${ALLOW_WARNINGS:-0}" = "1" ]; then
    swift build -c "$CONFIGURATION"
else
    swift build -c "$CONFIGURATION" -Xswiftc -warnings-as-errors
fi

STAGING_ROOT="$(mktemp -d "$ROOT/.build/iris-app.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP="$STAGING_ROOT/Iris.app"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path 2>/dev/null || true)"
if [ -n "${BIN_PATH:-}" ] && [ -x "$BIN_PATH/IrisMacOS" ]; then
    BIN="$BIN_PATH/IrisMacOS"
else
    BIN="$ROOT/.build/$CONFIGURATION/IrisMacOS"
fi
ICON_SRC="$ROOT/Assets/icon.svg"

if [ ! -x "$BIN" ]; then
    echo "error: missing $BIN" >&2
    exit 1
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/IrisMacOS"

# App icon: the SVG in Assets is the single hand-drawn image source.
# It is rasterized here at build time (no checked-in PNGs), then packed
# into an .icns with the system icon tools.
if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 && [ -f "$ICON_SRC" ]; then
    ICONSET="$(mktemp -d)/Iris.iconset"
    mkdir -p "$ICONSET"
    raster() {
        # $1 = pixel size, $2 = output name
        sips -s format png -z "$1" "$1" "$ICON_SRC" --out "$ICONSET/$2" >/dev/null
    }
    raster 16 "icon_16x16.png"
    raster 32 "icon_16x16@2x.png"
    raster 32 "icon_32x32.png"
    raster 64 "icon_32x32@2x.png"
    raster 128 "icon_128x128.png"
    raster 256 "icon_128x128@2x.png"
    raster 256 "icon_256x256.png"
    raster 512 "icon_256x256@2x.png"
    raster 512 "icon_512x512.png"
    raster 1024 "icon_512x512@2x.png"
    iconutil --convert icns --output "$APP/Contents/Resources/Iris.icns" "$ICONSET"
    rm -rf "$(dirname "$ICONSET")"
else
    echo "warning: icon tools or Assets/icon.svg missing; building without an icon" >&2
fi

ICON_KEYS=""
if [ -f "$APP/Contents/Resources/Iris.icns" ]; then
    ICON_KEYS="    <key>CFBundleIconFile</key>
    <string>Iris</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Iris</string>
    <key>CFBundleExecutable</key>
    <string>IrisMacOS</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.amscotti.iris</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Iris</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Anthony Scotti. MIT License.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Iris needs microphone access to transcribe your dictation.</string>
$ICON_KEYS
</dict>
</plist>
PLIST

INFO_PLIST="$APP/Contents/Info.plist"
plutil -lint "$INFO_PLIST" >/dev/null
for key in CFBundleExecutable CFBundleIdentifier CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion NSMicrophoneUsageDescription; do
    if ! /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" >/dev/null 2>&1; then
        echo "error: generated Info.plist is missing required key $key" >&2
        exit 1
    fi
done
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")" != "$VERSION" ] || \
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")" != "$BUILD" ]; then
    echo "error: generated Info.plist version metadata does not match VERSION/BUILD" >&2
    exit 1
fi

# Signed with the hardened runtime so the bundle matches a distributed build.
# The audio-input entitlement travels with the signature: without it the
# system rejects microphone requests before consulting TCC, so no prompt
# appears and the app never shows up under Privacy > Microphone.
#
# Ad-hoc signatures (the default) are identified by their exact code hash, so
# every new build is a different app to privacy settings: Microphone and
# Accessibility must be granted again after each update. Signing with any
# stable certificate keeps those grants, for example a self-signed
# code-signing certificate (see README "Distribution and signing"):
#   SIGN_IDENTITY="Iris Self-Signed" make dist
# For a Developer ID + notarized build (Gatekeeper then opens it normally):
#   1. SIGN_IDENTITY="Developer ID Application: <Team Name> (<Team ID>)" \
#        VERSION=x.y.z make dist
#   2. xcrun notarytool submit dist/Iris-x.y.z-macos.zip --wait \
#        --keychain-profile <profile>   (notarytool takes a zip, not an .app)
#   3. xcrun stapler staple Iris.app
#   4. make zip VERSION=x.y.z            (re-zip the stapled app)
TIMESTAMP_FLAG="--timestamp=none"
case "$SIGN_IDENTITY" in
    "Developer ID Application"*) TIMESTAMP_FLAG="--timestamp" ;;
esac
codesign --force --options runtime "$TIMESTAMP_FLAG" \
    --entitlements "$ROOT/Assets/Iris.entitlements" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
if ! codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.device.audio-input"; then
    echo "error: signed bundle is missing the com.apple.security.device.audio-input entitlement; mic prompt will never appear" >&2
    exit 1
fi

# Re-check after compilation/signing: Iris may have launched while building.
swift "$ROOT/Scripts/assert_app_stopped.swift" "$TARGET_APP"
rm -rf "$TARGET_APP"
mv "$APP" "$TARGET_APP"
# Final check: a launch inside the rm/mv window still replaced a live
# bundle (the window cannot be closed without a lock both the app and this
# script honor). Fail loudly so the user quits and rebuilds to keep privacy
# approvals intact.
if ! swift "$ROOT/Scripts/assert_app_stopped.swift" "$TARGET_APP"; then
    echo "error: Iris launched during installation; quit it and rebuild so privacy approvals stay valid" >&2
    exit 1
fi
echo "Built $TARGET_APP ($CONFIGURATION $VERSION build $BUILD)"
