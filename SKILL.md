---
name: kaitu-mihomo-proxy
description: Use when deploying mihomo+Kaitu egress or checking leaks.
version: 1.1.0
author: fisher, Hermes Agent
license: MIT
platforms: [macos]
metadata:
  hermes:
    tags: [proxy, mihomo, kaitu, tun, dns-leak]
    related_skills: [home-lab-network]
---

# mihomo + Kaitu two-layer proxy (B architecture)

Kaitu is demoted to a plain SOCKS5 egress; the mihomo kernel owns TUN, DNS and split routing. The goal is to get mihomo's rule engine (process-level matching, geosite rule-sets, fake-ip) while keeping Kaitu's nodes and censorship-resistant transport.

In short: **mihomo kernel + Kaitu**.

## When to Use

- Standing up the mihomo kernel + Kaitu egress on a new device
- Debugging "the proxy is up but some sites are slow or assets never load"
- Auditing egress geography and DNS leaks
- Don't use for: plain Clash/Verge subscription setups, or problems inside Kaitu's own TUN mode

## Architecture

```
app traffic
   ↓
mihomo (root daemon) — TUN utun5 = 198.18.0.1/30, fake-ip DNS 198.18.0.2, mixed-port 7897
   ↓ rules: domestic DIRECT / everything else → PROXY group → KAITU
Kaitu (root daemon) — SOCKS5 egress only on 127.0.0.1:1080, mode: proxy (builds no TUN)
   ↓
k2v5 node → real egress IP
```

Critical: Kaitu must stay in `mode: proxy`. The moment it builds its own TUN it competes with mihomo for routes.

## Reference values (replace per device)

| Item | Value on the reference machine |
|---|---|
| Config dir | `~/.config/mihomo-tun` |
| mihomo binary | `~/.local/bin/mihomo` |
| Kaitu CLI | `/Applications/Kaitu.app/Contents/MacOS/k2` |
| Active NIC | `en5` (wired); Wi-Fi is `en0` |
| TUN device | `utun5` |
| Ports | 1080 SOCKS5 / 7897 mixed / 9099 controller / 1777 Kaitu API |
| Proxy group | `PROXY` |

## Deployment

1. **Install Kaitu and connect a node.** Pick a node in the App, click Connect. `k2 status` must report `state: connected`.
   Done when: `k2 status | grep connected` returns a line.

2. **Install the mihomo kernel** at `~/.local/bin/mihomo`; `mihomo -v` prints a version.

3. **Create the config dir** and drop in `ruleset/{Local-IP,China-Site,China-IP}.mrs` plus `GeoSite.dat`. Both `GEOSITE,google` and `nameserver-policy geosite:cn` depend on that file; the kernel refuses to start without it.

4. **Write `config.yaml`** following `references/mihomo-config.md`. Four non-negotiables:
   socks5 upstream `127.0.0.1:1080` with `udp: true`; `tun.enable` plus `dns-hijack: ["any:53"]`; `nameserver` entries carrying the `#KAITU` suffix so DoH leaves through the proxy; `GEOSITE,google` above every `RULE-SET` line.

5. **Convert Kaitu to proxy mode**: `k2b-node sync` (reads the live `k2v5://` URL out of `k2 status`, rewrites `kaitu-proxy.yaml`, calls `k2 up`).
   Done when: `k2 status` reports `mode: proxy` and `nc -z 127.0.0.1 1080` succeeds.

6. **Validate the config**: `mihomo -t -d <dir> -f <dir>/config.yaml` must print `test is successful`.

7. **Install the root daemon** `com.fisher.k2b` running `start-b.sh` (`templates/start-b.sh`), `KeepAlive: true`.
   Done when: `ifconfig | grep 'inet 198.18.0.1'` returns a line.

8. **Install the user-level keepalive** `com.fisher.kaitu-proxy-keep` (`templates/kaitu-proxy-keep.sh`, `StartInterval 120`).

9. **Hot-reload rule changes instead of restarting**:
   ```bash
   curl -X PUT -H "Authorization: Bearer <secret>" \
     -d '{"path":"<dir>/config.yaml"}' \
     'http://127.0.0.1:9099/configs?force=true'
   ```
   `204` means applied, with live connections untouched.

## Verification (run after every change)

Full commands live in `references/leak-verification.md`. All six must hold:

1. **Egress geography**: `curl -s https://ipinfo.io/$(curl -s https://api.ipify.org)/json` matches the expected city/country.
2. **What Google sees**: `curl -s 'https://dns.google/resolve?name=o-o.myaddr.l.google.com&type=TXT'` must return `edns0-client-subnet <your egress>/24`. This is the far end reporting, not an inference.
3. **Rule hits**: `GET /rules` shows `GeoSite google` `hitCount` climbing, and `China-Site` not climbing for Google hosts.
4. **Physical-NIC capture**: `sudo tcpdump -i <active-nic> -n 'port 53 or port 853'` during cold lookups must show domestic DNS only, never plaintext queries for the target hosts.
5. **IPv6 closed**: no global v6 address, no v6 default route, v6 connects fail.
6. **No collateral damage**: domestic sites and the LAN still work.

## Pitfalls

**1. The China-Site rule-set claims Google static assets.**
`China-Site.mrs` (~136k entries) contains `gstatic.com`, `googleapis.com` and friends. A match sends them DIRECT, then each request burns a 5 s timeout. A single Gmail page pulls a dozen of them — that, not the node, is why "the proxy works but Gmail is slow". Fix: put `GEOSITE,google` plus explicit `DOMAIN-SUFFIX` lines above every `RULE-SET`. Pre-check with `grep -c 'dial DIRECT (match RuleSet/China-Site)' boot.log`.

**2. `strings` cannot find domains inside a rule-set.**
`.mrs` is a compressed trie; `zstdcat | strings` yields no plaintext either. Determine which set owns a host from runtime logs or `/rules` hit counts. Don't waste time decoding.

**3. IPv6 bypasses the TUN entirely (the most hidden leak).**
mihomo runs `ipv6: false` and its TUN carries only an IPv4 address, so v6 traffic never enters the kernel: it leaves with the host's real IPv6 address. That address is exposed to the far end, and an app with its own DoH can fetch AAAA and connect directly. **Disable IPv6 on every network service** (`-setv6off`) and have the watchdog re-check every 60 s, because a newly joined network comes up `Automatic`.
Check: `ifconfig | grep inet6 | grep -v 'fe80\|::1\|fdfe\|fd7a'` must be empty.

**4. System DNS regresses whenever the link is rebuilt.**
`networksetup -setdnsservers` writes service config, but macOS sometimes keeps using the DHCP resolver. Verify functionally — ask whether real resolution returns fake-ip (`198.18.x`), not what the config says. Repair in four escalating steps: write prefs → HUP configd and flush caches → bounce the NIC to rebuild the link → background watchdog re-checks.

**5. Rotate logs by truncation, never by rename.**
mihomo inherits the `exec >>` fd; after a rename it keeps appending to the old inode and rotation does nothing. `exec >>` is `O_APPEND`, so `: > boot.log` resets the offset to zero with no sparse hole. `tail -c 5M` first to keep the tail.

**6. `log-level: info` writes hundreds of MB.**
A few lines per connection reaches 150 MB in three days. At `warning` the same traffic grows zero. Turn it back down after debugging.

**7. Node switches go through the App, then `k2b-node sync`.**
Cached cert pins go stale; hand-building a URL from the cached list fails with `tls: failed to verify certificate` or `CRYPTO_ERROR`, and there is no fallback path — the machine loses all connectivity. `sync` must run after Connect.

**8. `dns resolve failed` is not automatically a config bug.**
Check whether the name is CNAME-only with no A record (`hif-dliq.deepseek.com` → `huaweicloudwaf.com` is the canonical example). Query `GET /dns/query?name=X&type=A` and read Status/Answer before touching `nameserver-policy`.

**9. HK nodes break OpenAI and Anthropic.**
Neither vendor serves Hong Kong. Japan works for both. This architecture has a single upstream, so switching nodes is global: the AI hosts move with Gmail.

**10. On this Mac `sudo` is interactive (Touch ID / password).**
A tool session cannot complete a root step on its own — don't wait for a prompt, and don't split the work across several `sudo` calls. Package the whole root flow (backup → action → `kickstart` → poll for `inet 198.18.0.1` → self-test egress and key domains) into **one** self-checking script and hand the user a single `sudo bash <path>` line. The script must print before/after evidence.

**11. Editing a script is not applying it.**
The daemon runs the copy it read at launch. Either `kickstart -k`, or state plainly that the change lands on the next restart. When the edit is a safety net (e.g. re-arming v6 off) and the live system is already safe from a manual one-off, deferring the restart instead of forcing downtime is the right call.

## Other platforms

The shape is unchanged; only the plumbing differs.

| macOS | Linux |
|---|---|
| launchd `com.fisher.k2b` | systemd unit with `Restart=always` |
| `networksetup -setdnsservers` / `-setv6off` | `resolvectl dns` / `sysctl net.ipv6.conf.all.disable_ipv6=1` |
| `dscacheutil` + `mDNSResponder` | `resolvectl flush-caches` |
| `ifconfig utun` | `ip addr show` |
| `stat -f %z` | `stat -c %s` |

On Linux the TUN also needs `tun.auto-redirect` or nftables tproxy rules before it captures traffic. Rule ordering, the `#KAITU` DoH suffix and closing IPv6 are identical.

Windows: mihomo with `tun.auto-route` + `strict-route`; Kaitu again in `mode: proxy` exposing only 1080; allow mihomo through the firewall.

## Files

`templates/` holds working artifacts — only three paths need changing:

| File | Purpose |
|---|---|
| `templates/start-b.sh` | root launcher: start mihomo, four-stage DNS repair, disable IPv6, log rotation, watchdog |
| `templates/stop-b.sh` | roll back to A mode: restore DNS/v6, unload the daemon, Kaitu back to TUN |
| `templates/kaitu-proxy-keep.sh` | every 120 s, keep Kaitu in proxy mode |
| `templates/k2b-node` | `status` / `sync` / `list` CLI |
| `templates/com.fisher.k2b.plist` | root LaunchDaemon |
| `templates/com.fisher.kaitu-proxy-keep.plist` | user LaunchAgent |

`references/`:

| File | Contents |
|---|---|
| `references/mihomo-config.md` | `config.yaml` annotated section by section, rule order, hot reload, debug logging |
| `references/leak-verification.md` | the seven audit checks with exact commands and pass criteria |

## Verification checklist

- `k2b-node status` reports `connected | proxy` and the egress responds
- `mihomo -t` passes
- All six audit checks green
- Domestic and LAN traffic unaffected: `curl www.baidu.com` 200, `curl http://<gateway>` 200
- Zero global IPv6 addresses
