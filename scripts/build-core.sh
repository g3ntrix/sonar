#!/usr/bin/env bash
# Builds relayd (Go helper) as a universal macOS binary: bundle/relayd. Ad-hoc signed later by build-app.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Helpers/relayd"
OUT="$ROOT/bundle"
mkdir -p "$OUT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/relayd.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
( cd "$SRC" && go test -count=1 ./... >/dev/null )
for arch in arm64 amd64; do
  ( cd "$SRC" && CGO_ENABLED=0 GOOS=darwin GOARCH=$arch go build -trimpath -ldflags "-s -w" -o "$TMP/relayd-$arch" . )
done
lipo -create "$TMP/relayd-arm64" "$TMP/relayd-amd64" -output "$OUT/relayd"
chmod +x "$OUT/relayd"
echo "✔ $(file "$OUT/relayd")"
