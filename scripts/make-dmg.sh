#!/usr/bin/env bash
# Packages dist/Sonar.app into dist/Sonar-<version>.dmg with an Applications link, a background that shows the
# first-launch steps, and a "First launch" text file (the app is not notarized).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Sonar.app"
VERSION="${VERSION:-$(cat "$ROOT/VERSION")}"
DMG="$ROOT/dist/Sonar-$VERSION.dmg"
VOL="Sonar $VERSION"
[[ -d "$APP" ]] || { echo "error: run scripts/build-app.sh first" >&2; exit 1; }
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sonar-dmg.XXXXXX")"; RW="$STAGE.rw.dmg"
trap 'hdiutil detach "/Volumes/$VOL" -quiet >/dev/null 2>&1 || true; rm -rf "$STAGE" "$RW"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/docs/FIRST_LAUNCH.txt" "$STAGE/First launch - read me.txt"
mkdir -p "$STAGE/.background"
swift "$ROOT/scripts/make-dmg-background.swift" "$STAGE/.background/bg.png"
rm -f "$DMG"
hdiutil detach "/Volumes/$VOL" -quiet >/dev/null 2>&1 || true
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null
hdiutil attach "$RW" -noautoopen -quiet
# Finder layout (best effort: needs Finder automation permission; the DMG works without it).
osascript <<OSA || echo "note: Finder layout skipped"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 560}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set background picture of opts to file ".background:bg.png"
    set position of item "Sonar.app" of container window to {160, 170}
    set position of item "Applications" of container window to {500, 170}
    set position of item "First launch - read me.txt" of container window to {330, 360}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
sync
hdiutil detach "/Volumes/$VOL" -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
echo "✔ $DMG"
shasum -a 256 "$DMG"
