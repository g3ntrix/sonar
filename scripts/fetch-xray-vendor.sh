#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) xray binary into bundle/xray from the official release zips.
# Uses local zips when present (assets/ or LOCAL_XRAY_ZIP_ARM64 / LOCAL_XRAY_ZIP_X86), else downloads them.
# Sonar has no routing rules, so geoip/geosite are not bundled.
set -euo pipefail
XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bundle"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/xray.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}"
resolve() {
  local env="$1" asset="$2"
  for c in "$env" "$ROOT/assets/$asset"; do [[ -n "$c" && -f "$c" ]] && { echo "$c"; return; }; done
  echo "Downloading $URL/$asset" >&2
  curl -fsSL --retry 5 "$URL/$asset" -o "$WORK/$asset" && echo "$WORK/$asset"
}
ARM="$(resolve "${LOCAL_XRAY_ZIP_ARM64:-}" Xray-macos-arm64-v8a.zip)"
X86="$(resolve "${LOCAL_XRAY_ZIP_X86:-}" Xray-macos-64.zip)"
mkdir -p "$WORK/a" "$WORK/x" "$OUT"
unzip -oq "$ARM" xray -d "$WORK/a"
unzip -oq "$X86" xray -d "$WORK/x"
lipo -create "$WORK/a/xray" "$WORK/x/xray" -output "$OUT/xray"
chmod +x "$OUT/xray"
"$OUT/xray" version | head -1
echo "✔ $(file "$OUT/xray")"
