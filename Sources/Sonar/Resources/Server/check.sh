#!/usr/bin/env bash
# Sonar: read-only check of a VPS before installing. Changes nothing. Paste the output into the Sonar app.
kv() { printf 'SONAR-CHECK %s=%s\n' "$1" "$2"; }
. /etc/os-release 2>/dev/null
kv os "${ID:-unknown}"
kv os_version "${VERSION_ID:-unknown}"
kv arch "$(uname -m)"
kv user "$(id -un)"
if [ "$(id -u)" -eq 0 ]; then kv root yes
elif sudo -n true 2>/dev/null; then kv root sudo
elif command -v sudo >/dev/null 2>&1; then kv root sudo-password
else kv root no; fi
command -v python3 >/dev/null 2>&1 && kv python3 "$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')" || kv python3 missing
command -v systemctl >/dev/null 2>&1 && kv systemd yes || kv systemd no
kv echo_ignore_all "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo unknown)"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then kv firewall ufw
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then kv firewall firewalld
elif command -v iptables >/dev/null 2>&1; then kv firewall iptables
else kv firewall none; fi
systemctl list-unit-files 2>/dev/null | grep -q '^x-ui' && kv xui yes || kv xui no
systemctl is-active --quiet icmp-relay 2>/dev/null && kv other_relay yes || kv other_relay no
[ -x /usr/local/bin/hysteria ] && kv hysteria yes || kv hysteria no
[ -f /etc/sonar/profile ] && kv sonar "$(cat /etc/sonar/profile)" || kv sonar no
(fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1) && kv apt_busy yes || kv apt_busy no
kv done yes
