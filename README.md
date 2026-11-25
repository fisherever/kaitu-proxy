# kaitu-proxy

A two-layer proxy built from the **mihomo kernel + Kaitu**: Kaitu acts purely as a SOCKS5 egress, mihomo owns the TUN device, DNS and split routing.

This repo is both a deployable configuration and a Hermes Agent skill (`SKILL.md`). It targets macOS and includes substitution notes for Linux and Windows.

## Why this shape

Kaitu's built-in TUN mode is a single global path. It cannot express "domestic direct + named hosts via the node + per-process routing". Demoting Kaitu to a SOCKS5 egress (`mode: proxy`) and letting mihomo own the TUN gets you both:

- geosite / rule-set level split routing (domestic direct, everything else through the node)
- per-process rules (ChatGPT forced through the node, Tailscale forced direct)
- fake-ip DNS plus `dns-hijack`, so plaintext DNS has nowhere to escape
- Kaitu's own nodes and censorship-resistant transport

```
app traffic
   ↓
mihomo (root daemon) — TUN 198.18.0.1/30, fake-ip DNS 198.18.0.2, mixed-port 7897
   ↓ rules: domestic DIRECT / everything else → PROXY group → KAITU
Kaitu (root daemon) — SOCKS5 egress only on 127.0.0.1:1080, mode: proxy (builds no TUN)
   ↓
k2v5 node → real egress IP
```

Critical: Kaitu must stay in `mode: proxy`. The moment it builds its own TUN it competes with mihomo for routes.

## Three real faults this configuration fixes

| Fault | Symptom | Cause |
|---|---|---|
| Google static assets time out | Gmail / Chrome feel slow; each resource stalls 5 s | The `China-Site` rule-set (~136k entries) contains `gstatic.com` and `googleapis.com`, so they match DIRECT |
| Log growth | `boot.log` reaches 150 MB in three days | `log-level: info` writes a few lines per connection, with no rotation |
| IPv6 bypasses the proxy | The host's real ISP IPv6 address is exposed to the far end | mihomo runs `ipv6: false` and the TUN has no v6 address, so v6 traffic never enters the kernel |

The fixes live in `references/` and in `templates/start-b.sh`.

## Quick start

Prerequisites: Kaitu installed and connected from the App; mihomo kernel installed.

```bash
# 1. Config directory
mkdir -p ~/.config/mihomo-tun
# place config.yaml here (see references/mihomo-config.md)
# place ruleset/{Local-IP,China-Site,China-IP}.mrs and GeoSite.dat here

# 2. Validate
mihomo -t -d ~/.config/mihomo-tun -f ~/.config/mihomo-tun/config.yaml

# 3. Convert Kaitu to proxy mode
./templates/k2b-node sync
./templates/k2b-node status      # expect: state: connected | mode: proxy

# 4. Expand the __HOME__ placeholders (launchd and the root daemon cannot use $HOME)
mkdir -p /tmp/kaitu-proxy
for f in templates/*; do sed "s|__HOME__|$HOME|g" "$f" > "/tmp/kaitu-proxy/$(basename "$f")"; done
grep -c "__HOME__" /tmp/kaitu-proxy/* 2>/dev/null | grep -v ":0" && echo "WARNING: placeholder left" || echo "placeholders expanded"

# 5. Install the daemons (needs root)
sudo cp /tmp/kaitu-proxy/start-b.sh ~/.config/mihomo-tun/
sudo cp /tmp/kaitu-proxy/stop-b.sh  ~/.config/mihomo-tun/
sudo cp /tmp/kaitu-proxy/local.mihomo.k2b.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/local.mihomo.k2b.plist

# 6. Install the keepalive (user level)
cp /tmp/kaitu-proxy/local.mihomo.kaitu-proxy-keep.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.mihomo.kaitu-proxy-keep.plist
```

`__HOME__` is a placeholder on purpose: the launcher is started by launchd in the root domain,
where `$HOME` is `/var/root`, so neither `$HOME` nor `~` expands correctly. `sed` at install time
is the only form that works for both the scripts and the plists. `k2b-node` has no placeholder —
it resolves paths via `expanduser()` at runtime.

Roll back to plain Kaitu TUN mode:

```bash
sudo ~/.config/mihomo-tun/stop-b.sh
```

## Layout

| Path | Purpose |
|---|---|
| `SKILL.md` | the full skill: deployment steps, 11 pitfalls, cross-platform notes |
| `references/mihomo-config.md` | `config.yaml` annotated section by section, rule order, hot reload, debug logging |
| `references/leak-verification.md` | seven audit checks for egress, DNS and IPv6, with pass criteria |
| `references/page-load-diagnosis.md` | per-resource protocol and timing recipe for "the page is slow but curl is fine" |
| `templates/start-b.sh` | root launcher: start mihomo, four-stage DNS repair, disable IPv6, log rotation, watchdog |
| `templates/stop-b.sh` | roll back to A mode: restore DNS/v6, unload the daemon, Kaitu back to TUN |
| `templates/kaitu-proxy-keep.sh` | every 120 s, keep Kaitu in proxy mode |
| `templates/k2b-node` | `status` / `sync` / `list` CLI |
| `templates/local.mihomo.k2b.plist` | root LaunchDaemon |
| `templates/local.mihomo.kaitu-proxy-keep.plist` | user LaunchAgent |

Only a few values need changing per device: the `D` / `K` / `MH` paths inside the scripts, the plist `Label`s, and the NIC name in `relink_wifi()` (`en0` is Wi-Fi; wired adapters differ).

## Verification

At minimum, after any rule change, node switch or daemon restart:

```bash
# egress geography
curl -s https://api.ipify.org; echo
# the subnet Google itself observed (hardest evidence)
curl -s 'https://dns.google/resolve?name=o-o.myaddr.l.google.com&type=TXT'
# DNS hijack test: all four public resolvers must answer with fake-ip
for s in 8.8.8.8 1.1.1.1 114.114.114.114 223.5.5.5; do
  printf '%-18s ' "@$s"; dig +short +time=3 +tries=1 A www.google.com @$s | head -1
done
# IPv6 must be empty
ifconfig | grep inet6 | grep -v 'fe80\|::1\|fdfe\|fd7a'
```

Full pass criteria in `references/leak-verification.md`.

## Using it as a Hermes skill

```bash
ln -s "$PWD" ~/.hermes/skills/kaitu-proxy
```

Then "set up mihomo + Kaitu on this machine" or "audit egress IP and DNS leaks" will load it automatically.

## Caveats

- This is a **personal configuration** and ships no node credentials. `kaitu-proxy.yaml` (which carries the full `k2v5://` URL and cert pins) is deliberately excluded from version control.
- Switch nodes only via **App → Connect → `k2b-node sync`**. Cached cert pins go stale; hand-built URLs fail with `tls: failed to verify certificate`, and there is no fallback path, so the machine loses all connectivity.
- A node switch is global: there is a single upstream SOCKS egress, so moving Gmail also moves ChatGPT / Claude. Neither OpenAI nor Anthropic serves Hong Kong.

## License

MIT
