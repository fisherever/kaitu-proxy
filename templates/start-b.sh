#!/bin/bash
# B-architecture launcher (root) — Kaitu (SOCKS5 1080) → mihomo (TUN + rules + fake-ip DNS)
#
# Per-device changes: the three variables below (D, K, MH), and the NIC name in relink_wifi().
#
# DNS is the most fragile part: service config says 198.18.0.2, but the active resolver can
# still be pinned to DHCP (macOS only pushes prefs down to the State layer when the link is
# rebuilt). Hence four escalating stages:
#   1) networksetup writes service config (skipping Tailscale so MagicDNS survives)
#   2) HUP configd + flush the resolver cache
#   3) still broken -> bounce the NIC to rebuild the link
#   4) background watchdog re-checks every 60s using REAL resolution, not the config
D=/Users/fisher/.config/mihomo-tun
K=/Applications/Kaitu.app/Contents/MacOS/k2
MH=/Users/fisher/.local/bin/mihomo

# Log rotation: boot.log is root-owned and mihomo inherited this fd.
# Truncate (": >"), never rename — after a rename the process keeps writing to the old inode
# and rotation achieves nothing. "exec >>" is O_APPEND, so a truncate resumes at offset 0
# with no sparse hole.
LOGMAX=$((20*1024*1024))
rotate_log() {
  [ -f "$D/boot.log" ] || return 0
  [ "$(stat -f %z "$D/boot.log")" -gt "$LOGMAX" ] || return 0
  tail -c 5242880 "$D/boot.log" > "$D/boot.log.1" 2>/dev/null
  : > "$D/boot.log"
}
rotate_log

exec >> "$D/boot.log" 2>&1
echo "=== $(date '+%F %T') start-b v6 ==="

services() {
  networksetup -listallnetworkservices | tail -n +2 | while IFS= read -r s; do
    case "$s" in \**) continue ;; esac
    [ "$s" = "Tailscale" ] && continue
    [ -n "$s" ] && echo "$s"
  done
}

# Functional criterion: real resolution must return a fake-ip (198.18.x)
dns_works() {
  ip=$(dscacheutil -q host -a name www.google.com 2>/dev/null | awk '/ip_address/ {print $2; exit}')
  case "$ip" in 198.18.*) return 0 ;; *) echo "    bad resolution: www.google.com -> ${ip:-none}"; return 1 ;; esac
}

write_prefs() {
  services | while IFS= read -r s; do
    networksetup -setdnsservers "$s" 198.18.0.2 >/dev/null 2>&1
  done
  networksetup -setdnsservers "Tailscale" Empty >/dev/null 2>&1
  disable_v6
}

# IPv6 must be off: mihomo runs ipv6:false and its TUN has no v6 address, so v6 traffic
# never enters mihomo at all — it leaves with the host's real IPv6 address.
# Effect: the real v6 address is exposed to the far end, and an app with its own DoH can
# fetch AAAA and bypass the proxy entirely.
# Tailscale is left alone (it has its own utun and only carries v6 inside the tailnet).
disable_v6() {
  services | while IFS= read -r s; do
    networksetup -setv6off "$s" >/dev/null 2>&1
  done
}

restore_v6() {
  services | while IFS= read -r s; do
    networksetup -setv6automatic "$s" >/dev/null 2>&1
  done
}

flush_dns() {
  killall -HUP configd 2>/dev/null
  sleep 1
  dscacheutil -flushcache 2>/dev/null
  killall -HUP mDNSResponder 2>/dev/null
  sleep 2
}

relink_wifi() {
  echo "    rebuilding Wi-Fi link (en0)"
  networksetup -setairportpower en0 off >/dev/null 2>&1
  sleep 4
  networksetup -setairportpower en0 on >/dev/null 2>&1
  for i in $(seq 1 12); do
    sleep 5
    ifconfig en0 2>/dev/null | grep -q "inet 192.168" && break
  done
  echo "    link back: $(ifconfig en0 2>/dev/null | awk '/inet /{print $2; exit}')"
  sleep 2
}

apply_dns() {
  local i
  for i in 1 2 3; do
    write_prefs; flush_dns
    dns_works && { echo "  DNS ok (round $i, prefs+flush)"; return 0; }
    if [ "$i" = "2" ]; then relink_wifi; fi
  done
  dns_works && { echo "  DNS ok (after link rebuild)"; return 0; }
  echo "  DNS still broken"
  return 1
}

restore_dns() {
  services | while IFS= read -r s; do networksetup -setdnsservers "$s" Empty >/dev/null 2>&1; done
  flush_dns
}

rollback() {
  echo "HARD FAIL -> rolling back to A mode"
  restore_dns
  restore_v6
  URL=$(sed -n 's/^server: "\(.*\)"$/\1/p' "$D/kaitu-proxy.yaml" | head -1)
  [ -n "$URL" ] && $K up "$URL" >/dev/null 2>&1
}

pkill -f "$MH" 2>/dev/null && sleep 2

$K up "$D/kaitu-proxy.yaml" >/dev/null 2>&1 || echo "warn: kaitu up failed"
sleep 4

$MH -d "$D" -f "$D/config.yaml" &
MP=$!

ok=0
for i in $(seq 1 20); do
  ifconfig 2>/dev/null | grep -q "inet 198.18.0.1" && { ok=1; break; }
  kill -0 $MP 2>/dev/null || break
  sleep 1
done
if [ "$ok" != "1" ]; then
  echo "TUN not established"; rollback; wait $MP 2>/dev/null; exit 1
fi
echo "TUN ok: 198.18.0.1"

apply_dns || echo "warning: DNS not ready, the watchdog keeps retrying"

# Watchdog: functional criterion + at most one link rebuild per 5 minutes, so a bad
# state does not turn into a reboot loop of network drops
(
  last_relink=$(date +%s)
  while kill -0 $MP 2>/dev/null; do
    sleep 60
    rotate_log
    # A newly joined network service (fresh Wi-Fi / adapter) comes up IPv6 Automatic and
    # would silently reopen the v6 bypass
    if ifconfig 2>/dev/null | grep "inet6" | grep -qv "fe80\|::1\|fdfe\|fd7a"; then
      echo "$(date '+%F %T') watchdog: global IPv6 seen, disabling again"
      disable_v6
    fi
    dns_works && continue
    echo "$(date '+%F %T') watchdog: DNS drifted"
    write_prefs; flush_dns
    dns_works && { echo "    fixed (prefs+flush)"; continue; }
    now=$(date +%s)
    if [ $((now - last_relink)) -gt 300 ]; then
      relink_wifi; last_relink=$(date +%s)
      apply_dns >/dev/null 2>&1
      echo "    after rebuild: $(dns_works && echo ok || echo STILL_BAD)"
    else
      echo "    skipping rebuild (already tried within 5 min)"
    fi
  done
) &

echo "self-test https://1.1.1.1 -> $(curl -s -m 10 -o /dev/null -w '%{http_code}' https://1.1.1.1)"
echo "B mode ready (mihomo pid=$MP)"
wait $MP
