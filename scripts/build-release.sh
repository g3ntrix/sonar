#!/usr/bin/env bash
# Builds the app and DMG, writes release notes with the SHA-256, and (only after you type "yes") uploads the DMG
# as a GitHub release to the public releases-only repo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${RELEASES_REPO:-g3ntrix/sonar-releases}"
VERSION="$(cat "$ROOT/VERSION")"
"$ROOT/scripts/build-app.sh"
"$ROOT/scripts/make-dmg.sh"
DMG="$ROOT/dist/Sonar-$VERSION.dmg"
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
NOTES="$ROOT/dist/CHANGELOG-entry.md"
awk -v v="## $VERSION" '$0==v{f=1;next} /^## /{f=0} f' "$ROOT/CHANGELOG.md" > "$NOTES"
cat >> "$NOTES" <<MD

**SHA-256** \`$SHA\`  Sonar-$VERSION.dmg

Sonar is not notarized. If macOS blocks it: System Settings → Privacy & Security → Open Anyway,
or run \`xattr -dr com.apple.quarantine /Applications/Sonar.app\`.
MD
echo; cat "$NOTES"; echo
# Leak check before anything leaves this Mac.
"$ROOT/scripts/check-secrets.sh"
read -r -p "Publish v$VERSION to github.com/$REPO? Type yes: " ok
[[ "$ok" == "yes" ]] || { echo "Not published."; exit 0; }
gh release create "v$VERSION" "$DMG" --repo "$REPO" --title "Sonar $VERSION" --notes-file "$NOTES"
