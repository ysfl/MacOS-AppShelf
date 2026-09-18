#!/bin/zsh
# Pre-release visual check.
#
# Unit tests cannot see a toolbar that fell apart. This builds the app, drives it through
# the appearance and language combinations, and writes one screenshot per state so a human
# can look before a release goes out. Requires Screen Recording permission for the shell.
#
# Usage: Scripts/visual-check.sh [output-dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${1:-$PROJECT_DIR/dist/visual-check}"
APP_ID="local.dan.AppShelf"
DOMAIN="local.dan.AppShelf"
BUNDLE="$PROJECT_DIR/dist/AppShelf.app"

# `screencapture -l` needs a CoreGraphics window id, which AppleScript cannot give.
# Built once per run into a temp directory rather than committed as a binary.
TOOL_DIR="$(mktemp -d)"
cat > "$TOOL_DIR/windowid.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let needle = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppShelf"
// The owner name is the app for every window it owns, so a second argument narrows by title.
let titleNeedle = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                            kCGNullWindowID) as? [[String: Any]] else { exit(2) }
var best: (id: UInt32, area: CGFloat)?
for w in list {
    guard let owner = w[kCGWindowOwnerName as String] as? String,
          let num = w[kCGWindowNumber as String] as? UInt32,
          let layer = w[kCGWindowLayer as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    guard layer == 0, owner.contains(needle) else { continue }
    if !titleNeedle.isEmpty {
        let title = (w[kCGWindowName as String] as? String) ?? ""
        guard title.contains(titleNeedle) else { continue }
    }
    let area = (b["Width"] ?? 0) * (b["Height"] ?? 0)
    if area < 20_000 { continue }
    if best == nil || area > best!.area { best = (num, area) }
}
guard let win = best else { exit(3) }
print(win.id)
SWIFT
swiftc -O "$TOOL_DIR/windowid.swift" -o "$TOOL_DIR/windowid" 2>/dev/null \
  || { echo "cannot build the window-id helper; is a Swift toolchain installed?" >&2; exit 1; }
window_id() { "$TOOL_DIR/windowid" "${1:-应用架}" "${2:-}" 2>/dev/null || true; }

mkdir -p "$OUT"
rm -f "$OUT"/*.png(N)

echo "==> building"
"$SCRIPT_DIR/build-app.sh" debug

# The matrix overwrites these two keys, so record exactly what they held beforehand and put
# it back on exit. A key that was absent has to be deleted again, not written as empty.
DRIVEN_KEYS=(AppShelf.appearance AppShelf.language)
typeset -a PRESENT
for key in "${DRIVEN_KEYS[@]}"; do
  if [ -n "$(defaults read "$DOMAIN" "$key" 2>/dev/null || true)" ]; then
    PRESENT+=("yes")
  else
    PRESENT+=("no")
  fi
done
typeset -a PRIOR_VALUE
for key in "${DRIVEN_KEYS[@]}"; do
  PRIOR_VALUE+=("$(defaults read "$DOMAIN" "$key" 2>/dev/null || true)")
done

restore() {
  # `status` is a read-only special parameter in zsh, so the exit code goes elsewhere.
  local rc=$?
  local i=1
  local key
  osascript -e "tell application \"应用架\" to quit" 2>/dev/null || true
  for key in "${DRIVEN_KEYS[@]}"; do
    if [ "${PRESENT[$i]}" = "yes" ]; then
      defaults write "$DOMAIN" "$key" -string "${PRIOR_VALUE[$i]}"
    else
      defaults delete "$DOMAIN" "$key" 2>/dev/null || true
    fi
    i=$((i + 1))
  done
  rm -rf "$TOOL_DIR"
  echo "==> screenshots in $OUT"
  if [ "$rc" -eq 0 ]; then echo "==> prior preferences restored"; fi
  return "$rc"
}
trap restore EXIT

capture() {
  local label="$1"
  osascript -e "tell application \"$BUNDLE\" to quit" 2>/dev/null || true
  sleep 1.5
  open -a "$BUNDLE"
  sleep 4
  osascript -e 'tell application "应用架" to activate' 2>/dev/null || true
  sleep 1
  local wid
  wid="$(window_id 应用架)"
  if [ -n "$wid" ]; then
    screencapture -o -x -l"$wid" -t png "$OUT/$label.png" && echo "    captured $label"
  else
    echo "    !! no window for $label (is Screen Recording permitted?)" >&2
  fi
}

echo "==> matrix: appearance x language"
for appearance in system dark light; do
  defaults write "$DOMAIN" AppShelf.appearance -string "$appearance"
  for language in system en zh-Hans; do
    defaults write "$DOMAIN" AppShelf.language -string "$language"
    capture "${appearance}_${language}"
  done
done

echo "==> search ordering (typing wx must list 微信 before 企业微信)"
defaults delete "$DOMAIN" AppShelf.appearance 2>/dev/null || true
defaults delete "$DOMAIN" AppShelf.language 2>/dev/null || true
osascript -e "tell application \"$BUNDLE\" to quit" 2>/dev/null || true
sleep 1.5
open -a "$BUNDLE"; sleep 4
osascript <<'APPLESCRIPT' || true
tell application "System Events"
  tell process "应用架"
    set frontmost to true
    delay 0.6
    keystroke "wx"
    delay 1.2
    key code 126
    delay 0.5
  end tell
end tell
APPLESCRIPT
WID="$(window_id 应用架)"
if [ -n "$WID" ]; then
  screencapture -o -x -l"$WID" -t png "$OUT/search_wx_keyboard.png" && echo "    captured search_wx_keyboard"
else
  echo "    !! no window for search_wx_keyboard" >&2
fi

echo "==> settings panel"
osascript -e 'tell application "System Events" to tell process "应用架" to keystroke "," using command down' 2>/dev/null || true
sleep 2
SID="$(window_id 应用架 设置)"
[ -n "$SID" ] || SID="$(window_id 应用架 Settings)"
if [ -n "$SID" ]; then
  screencapture -o -x -l"$SID" -t png "$OUT/settings.png" && echo "    captured settings"
else
  echo "    !! settings window not captured" >&2
fi

echo
echo "Look at $OUT before releasing. The checks that cannot be automated are:"
echo "  - toolbar controls stay compact and aligned in every appearance"
echo "  - strokes are visible in both light and dark"
echo "  - the keyboard highlight is on the top search hit"
echo "  - the settings panel scrolls and nothing is clipped"
