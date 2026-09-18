#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="${1:-release}"

cd "$PROJECT_DIR"
# SwiftPM writes build products to .build; the final bundle is assembled below.
swift build -c "$CONFIG" --product AppShelf

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/AppShelf"
APP_PATH="$PROJECT_DIR/dist/AppShelf.app"
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT

# Recreate the bundle so stale resources from an earlier build cannot leak into a release.
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/AppShelf"
cp "$PROJECT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"

# Bundle the per-language JSON files so the UI can be localized at runtime.
mkdir -p "$APP_PATH/Contents/Resources/Localization"
cp "$PROJECT_DIR/Resources/Localization"/*.json "$APP_PATH/Contents/Resources/Localization/" 2>/dev/null || true

ICON_MASTER="$ICON_WORK/icon_1024x1024.png"
ICON_SET="$ICON_WORK/AppIcon.iconset"
mkdir -p "$ICON_SET"
# Generate one vector-like raster master, then let sips create Apple's required icon sizes.
swift "$PROJECT_DIR/Scripts/make-icon.swift" "$ICON_MASTER"

for specification in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"; do
    size="${specification%% *}"
    filename="${specification#* }"
    /usr/bin/sips -z "$size" "$size" "$ICON_MASTER" --out "$ICON_SET/$filename" >/dev/null
done

/usr/bin/iconutil -c icns "$ICON_SET" -o "$APP_PATH/Contents/Resources/AppIcon.icns"

# Ad-hoc signing lets macOS launch the locally built bundle without a developer account.
/usr/bin/codesign --force --deep --sign - "$APP_PATH" >/dev/null

echo "Built: $APP_PATH"
