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
# The version is the release's identity, so it has to be the one the notes tell people.
DOC_VERSION="$(sed -n 's/^## \([0-9][.0-9]*\).*/\1/p' "$PROJECT_DIR/CHANGELOG.md" | head -1)"
if [ "$VERSION" != "$DOC_VERSION" ]; then
    echo "Refusing to build $VERSION: CHANGELOG.md documents $DOC_VERSION as the latest release." >&2
    echo "Update CHANGELOG.md (and README.md) first, or pass the matching version." >&2
    exit 1
fi

# Always package the current source tree instead of relying on a previously built app.
APP_VERSION="$VERSION" "$SCRIPT_DIR/build-app.sh"

# The bundle must agree with the filename before a byte of DMG is written.
BUILT_PLIST="$PROJECT_DIR/dist/AppShelf.app/Contents/Info.plist"
BUILT_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$BUILT_PLIST")"
if [ "$BUILT_VERSION" != "$VERSION" ]; then
    echo "Refusing to package: the built app reports $BUILT_VERSION, not $VERSION." >&2
    exit 1
fi

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
