#!/bin/bash
# B-mode keepalive (user-level LaunchAgent, StartInterval 120)
#   healthy = state=connected and mode=proxy -> exit silently
#   connected but mode=tun (a node was picked and connected in the App) -> rewrite that node's
#       URL into proxy mode, preserving the chosen node
#   offline -> reconnect using the saved credentials
# Pure bash + sed, no python/yaml dependency.
#
# Per-device changes: K (Kaitu CLI), Y (kaitu-proxy.yaml path), plus the pgrep path and the
# launchctl label below.
launchctl print system/com.fisher.k2b >/dev/null 2>&1 || exit 0
pgrep -f "/Users/fisher/.local/bin/mihomo" >/dev/null 2>&1 || exit 0

K=/Applications/Kaitu.app/Contents/MacOS/k2
Y=/Users/fisher/.config/mihomo-tun/kaitu-proxy.yaml

S=$($K status 2>/dev/null)
ST=$(printf '%s' "$S" | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -1)
M=$(printf '%s' "$S" | sed -n 's/.*"mode"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -1)

[ "$ST" = "connected" ] && [ "$M" = "proxy" ] && exit 0

# Alive but in tun mode: take the current node URL and rewrite it as proxy mode
if [ "$ST" = "connected" ]; then
  URL=$(printf '%s' "$S" | tr ',' '\n' | sed -n 's/.*"via"[[:space:]]*:[[:space:]]*"\(k2v5:\/\/[^"]*\)".*/\1/p' | head -1)
  if [ -n "$URL" ]; then
    umask 077
    cat > "$Y" <<EOF
server: "$URL"
mode: proxy
proxy:
  listen: 127.0.0.1:1080
dns:
  direct:
    - 114.114.114.114:53
    - 223.5.5.5:53
  proxy:
    - 8.8.8.8:53
    - 1.1.1.1:53
routes:
  - match:
      all: true
    via: "$URL"
EOF
    chmod 600 "$Y"
    $K up "$Y" >/dev/null 2>&1
    exit 0
  fi
fi

# Offline: fall back to the saved credentials
[ -s "$Y" ] && $K up "$Y" >/dev/null 2>&1
exit 0
