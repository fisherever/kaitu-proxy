# mihomo config.yaml — essential sections (B architecture)

Only the mandatory parts and the easy-to-get-wrong ones. A complete working example lives on the reference machine at `~/.config/mihomo-tun/config.yaml`.

## Header

```yaml
mixed-port: 7897            # keep the legacy port so tools with it hardcoded still work
allow-lan: false
mode: rule
log-level: warning          # info writes hundreds of MB
ipv6: false                 # critical: v6 stays off
external-controller: 127.0.0.1:9099
secret: "<random string>"
find-process-mode: strict   # process-level routing (ChatGPT / Tailscale) depends on it
profile:
  store-selected: true
  store-fake-ip: true
```

## TUN

```yaml
tun:
  enable: true
  stack: gvisor
  auto-route: true
  auto-detect-interface: true
  strict-route: true
  dns-hijack: ["any:53"]    # hijack all plaintext DNS — the basis of "no leaks"
```

`strict-route` only covers IPv4. IPv6 has to be closed at the network-service layer; see SKILL.md pitfall 3.

## DNS

```yaml
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:           # these resolve for real, never fake
    - "+.ts.net"
    - "+.tailscale.com"
    - "+.tailscale.io"
    - "+.lan"
    - "+.arpa"
  nameserver:               # the #KAITU suffix forces this DoH through the proxy
    - "https://1.1.1.1/dns-query#KAITU"
    - "https://8.8.8.8/dns-query#KAITU"
  nameserver-policy:        # domestic names via domestic DNS — not a leak, those hosts resolve direct anyway
    "geosite:cn,private": ["223.5.5.5", "119.29.29.29", "114.114.114.114"]
  default-nameserver:       # bootstraps the DoH endpoints; they are literal IPs, fallback only
    - 223.5.5.5
    - 119.29.29.29
```

Without the `#KAITU` suffix the DoH queries leave directly from the host and DNS leaks.

## Upstream and group

```yaml
proxies:
  - name: KAITU
    type: socks5
    server: 127.0.0.1
    port: 1080
    udp: true               # without it QUIC/UDP fails silently

proxy-groups:
  - name: PROXY
    type: select
    proxies: [KAITU, DIRECT]
```

## rule-providers

```yaml
rule-providers:
  Local-IP:   {type: file, behavior: ipcidr, format: mrs, path: ./ruleset/Local-IP.mrs}
  China-Site: {type: file, behavior: domain, format: mrs, path: ./ruleset/China-Site.mrs}
  China-IP:   {type: file, behavior: ipcidr, format: mrs, path: ./ruleset/China-IP.mrs}
```

`GeoSite.dat` must sit in the `-d` directory, otherwise `GEOSITE,google` and `geosite:cn` cannot load.

## Rule order (the part that matters most)

Top to bottom; the wrong order breaks behaviour:

```yaml
rules:
  # 1. Google in full — must precede China-Site
  - GEOSITE,google,PROXY
  - DOMAIN-SUFFIX,gstatic.com,PROXY
  - DOMAIN-SUFFIX,googleapis.com,PROXY
  - DOMAIN-SUFFIX,googleusercontent.com,PROXY
  - DOMAIN-SUFFIX,googletagmanager.com,PROXY
  - DOMAIN-SUFFIX,google-analytics.com,PROXY
  - DOMAIN-SUFFIX,gvt1.com,PROXY
  - DOMAIN-SUFFIX,gvt2.com,PROXY

  # 2. Process level: AI tooling via the node, Tailscale direct
  - PROCESS-PATH-REGEX,(?i)/Applications/ChatGPT\\.app,PROXY
  - PROCESS-NAME,ChatGPT,PROXY
  - PROCESS-NAME,Tailscale,DIRECT
  - PROCESS-NAME,IPNExtension,DIRECT

  # 3. AI and developer hosts
  - DOMAIN-SUFFIX,openai.com,PROXY
  - DOMAIN-SUFFIX,anthropic.com,PROXY
  - DOMAIN-SUFFIX,claude.ai,PROXY
  - DOMAIN-KEYWORD,cursor,PROXY

  # 4. Direct allowlist (apple / icloud / notion / LAN devices)
  - DOMAIN-SUFFIX,apple.com,DIRECT
  - DOMAIN-SUFFIX,icloud.com,DIRECT

  # 5. Private ranges
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve

  # 6. Domestic rule-sets — last, they are greedy
  - RULE-SET,Local-IP,DIRECT,no-resolve
  - RULE-SET,China-Site,DIRECT
  - RULE-SET,China-IP,DIRECT

  # 7. Fallback
  - MATCH,PROXY
```

`China-Site` holds ~136k entries and includes Google static-asset hosts, so anything that must be proxied has to appear above it.

## Debug logging

Turn it on while diagnosing:

```bash
curl -X PATCH -H "Authorization: Bearer <secret>" \
  -d '{"log-level":"debug"}' http://127.0.0.1:9099/configs
```

Set it back to `warning` as soon as you are done or the log balloons. At debug level every DNS query names its real upstream:

```
[DNS] resolve www.google.com A from https://1.1.1.1:443/dns-query
```
