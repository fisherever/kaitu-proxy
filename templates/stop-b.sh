#!/bin/bash
# Roll back to A mode (plain Kaitu): restore DHCP DNS + IPv6, Kaitu back to TUN, unload the daemon
# Usage: sudo ./stop-b.sh
#
# Per-device: substitute __HOME__ (see README) and change the bootout label.
H=__HOME__
D=$H/.config/mihomo-tun
K=/Applications/Kaitu.app/Contents/MacOS/k2
MH=$H/.local/bin/mihomo

echo "1) Restoring DHCP DNS and IPv6 Automatic"
for svc in $(networksetup -listallnetworkservices | tail -n +2); do
  case "$svc" in \**) continue ;; esac
  networksetup -setdnsservers "$svc" Empty >/dev/null 2>&1
  networksetup -setv6automatic "$svc" >/dev/null 2>&1
  echo "   $svc -> DNS Empty / IPv6 Automatic"
done
dscacheutil -flushcache

echo "2) Unloading root daemon local.mihomo.k2b"
launchctl bootout system/local.mihomo.k2b 2>/dev/null && echo "   unloaded" || echo "   was not loaded"
rm -f /Library/LaunchDaemons/local.mihomo.k2b.plist
pkill -f "$MH" 2>/dev/null && echo "   mihomo stopped"

echo "3) Kaitu back to TUN mode"
URL=$(sed -n 's/^server: "\(.*\)"$/\1/p' "$D/kaitu-proxy.yaml" | head -1)
if [ -n "$URL" ]; then
  $K up "$URL" >/dev/null 2>&1
  $K status 2>/dev/null | /usr/bin/python3 -c 'import sys,json;d=json.load(sys.stdin);print("   state:",d.get("state"),"| mode:",d.get("config",{}).get("mode"))'
fi
echo "Done. Verify the egress with: curl -s https://ipinfo.io/ip"
