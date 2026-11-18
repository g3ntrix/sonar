#!/usr/bin/env bash
# Fails if a private credential, key or server IP shows up in the repo or build products.
# Values are read at run time from local private files and never printed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
needles=()
add() { [ -n "$1" ] && [ ${#1} -ge 6 ] && needles+=("$1"); }
if [ -f "$HOME/vpn-icmp.sh" ]; then
  while IFS= read -r v; do add "$v"; done < <(grep -oE '"(auth|password|pass|pinnedPeerCertSha256)":"[^"<$]+"' "$HOME/vpn-icmp.sh" | sed -E 's/^"[^"]+":"(.*)"$/\1/')
  while IFS= read -r v; do add "$v"; done < <(sed -nE 's/^LANPW="([^"<]+)".*/\1/p' "$HOME/vpn-icmp.sh")
fi
if [ -f "$HOME/.hy141_secrets" ]; then
  while IFS= read -r v; do add "$v"; done < <(grep -oE '[A-Za-z0-9+/=_-]{12,}' "$HOME/.hy141_secrets")
fi
needles+=("BEGIN RSA PRIVATE KEY" "BEGIN OPENSSH PRIVATE KEY")
# Extra values (server IPs etc.), one per line, in an untracked file.
if [ -f "$ROOT/.private/leak-needles.txt" ]; then
  while IFS= read -r v; do [[ -z "$v" || "$v" == \#* ]] && continue; add "$v"; done < "$ROOT/.private/leak-needles.txt"
fi
targets=("$ROOT/Sources" "$ROOT/Helpers" "$ROOT/Tests" "$ROOT/scripts" "$ROOT/Package.swift" "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$ROOT/docs/FIRST_LAUNCH.txt" "$ROOT/docs/RELEASES_README.md")
[ -d "$ROOT/dist" ] && targets+=("$ROOT/dist")
# ALL=1: also scan every other tracked file (docs, logo, reference/).
if [ "${ALL:-0}" = 1 ]; then
  while IFS= read -r f; do targets+=("$ROOT/$f"); done < <(git -C "$ROOT" ls-files docs logo reference)
fi
hits=0
for n in "${needles[@]}"; do
  for t in "${targets[@]}"; do
    [ -e "$t" ] || continue
    if grep -rFqa --exclude=check-secrets.sh -- "$n" "$t" 2>/dev/null; then
      f="$(grep -rFla --exclude=check-secrets.sh -- "$n" "$t" | head -3 | tr '\n' ' ')"
      echo "LEAK: a developer secret or IP (${#n} chars) appears in: $f"
      hits=$((hits + 1))
    fi
  done
done
# Also inside the DMG.
for d in "$ROOT"/dist/*.dmg; do
  [ -f "$d" ] || continue
  m="$(mktemp -d)"; hdiutil attach -nobrowse -readonly -mountpoint "$m" "$d" -quiet || continue
  for n in "${needles[@]}"; do grep -rFqa -- "$n" "$m" 2>/dev/null && { echo "LEAK inside $(basename "$d")"; hits=$((hits + 1)); }; done
  hdiutil detach "$m" -quiet; rmdir "$m"
done
echo "checked ${#needles[@]} values across sources, scripts, tests and build products"
[ $hits -eq 0 ] && echo "✔ no leaks" || { echo "✘ $hits leak(s)"; exit 1; }
