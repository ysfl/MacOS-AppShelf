#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-1.0.0}"
RELEASE_DIR="$PROJECT_DIR/release"
DMG_PATH="$RELEASE_DIR/AppShelf-$VERSION.dmg"
STAGE_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

cd "$PROJECT_DIR"
# Always package the current source tree instead of relying on a previously built app.
"$SCRIPT_DIR/build-app.sh"

mkdir -p "$RELEASE_DIR"
# The Applications symlink makes the DMG usable as a drag-to-install window.
/usr/bin/ditto "$PROJECT_DIR/dist/AppShelf.app" "$STAGE_DIR/应用架.app"
cp "$PROJECT_DIR/README.md" "$STAGE_DIR/使用说明.md"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
    -volname "应用架 $VERSION" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

(cd "$RELEASE_DIR" && shasum -a 256 "AppShelf-$VERSION.dmg" > "SHA256SUMS")
echo "Built: $DMG_PATH"
cat "$RELEASE_DIR/SHA256SUMS"
