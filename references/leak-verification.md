# Audit: egress geography and DNS leaks

All checks must hold at once. Re-run after any rule change, node switch or daemon restart.

## 1. Egress geography

```bash
IP=$(curl -s -m 8 https://api.ipify.org)
echo "egress IP: $IP"
curl -s -m 8 "https://ipinfo.io/$IP/json" | python3 -c \
  'import sys,json;d=json.load(sys.stdin);print(d.get("city"),d.get("region"),d.get("country"),"|",d.get("org"))'
```

Sample several times to confirm it does not drift (`for i in 1 2 3`).

## 2. How the far end sees us (hardest evidence)

`o-o.myaddr.l.google.com` is answered by Google's authoritative servers with the client subnet they observed — this is reporting, not inference:

```bash
curl -s -m 10 'https://dns.google/resolve?name=o-o.myaddr.l.google.com&type=TXT' \
  | python3 -c 'import sys,json;[print(a["data"]) for a in json.load(sys.stdin).get("Answer",[])]'
```

Expect `edns0-client-subnet <your egress>/24`. The second value is the resolver IP Google saw; ignore it.

Cross-check:

```bash
curl -s -m 8 https://www.cloudflare.com/cdn-cgi/trace | grep -E '^ip=|^loc='
```

## 3. Rule attribution

Two snapshots and a diff tells you exactly which host hit which rule:

```bash
S='<secret>'
snap() { curl -s -H "Authorization: Bearer $S" http://127.0.0.1:9099/rules \
  | python3 -c 'import sys,json;[print(r["type"]+"|"+r["payload"]+"|"+str((r.get("extra") or {}).get("hitCount",0))) for r in json.load(sys.stdin)["rules"]]'; }
snap > /tmp/r0
for d in www.google.com mail.google.com gemini.google.com antigravity.google; do
  curl -s -o /dev/null -m 6 "https://$d/"; done
snap > /tmp/r1
diff /tmp/r0 /tmp/r1 | grep '^>'
```

Pass: every increment lands on `GeoSite|google` or an explicit `DOMAIN-SUFFIX` line. **`RuleSet|China-Site` must not increment for these hosts.**

## 4. DNS hijack and real upstream

**Hijack test** — query any public resolver for a known host; it must answer with fake-ip:

```bash
for s in 8.8.8.8 1.1.1.1 114.114.114.114 223.5.5.5; do
  printf '%-18s ' "@$s"; dig +short +time=3 +tries=1 A www.google.com @$s | head -1
done
```

All `198.18.x` means the TUN owns port 53. A real IP (`142.251.x`, `74.125.x`) from any of them means some query path bypasses the TUN.

**Real upstream** — turn on debug and see which resolver served each host:

```bash
curl -X PATCH -H "Authorization: Bearer $S" -d '{"log-level":"debug"}' \
  http://127.0.0.1:9099/configs
# flush caches, then resolve a batch
for d in www.google.com mail.google.com www.baidu.com; do
  curl -s -H "Authorization: Bearer $S" "http://127.0.0.1:9099/dns/query?name=$d&type=A" >/dev/null; done
grep '\[DNS\] resolve' ~/.config/mihomo-tun/boot.log | tail -20
curl -X PATCH -H "Authorization: Bearer $S" -d '{"log-level":"warning"}' \
  http://127.0.0.1:9099/configs   # restore
```

Expect target hosts → `https://1.1.1.1:443/dns-query` or `8.8.8.8`; domestic hosts → `udp://223.5.5.5:53` and friends.

## 5. Physical-NIC capture (decisive)

Everything above only proves how mihomo is configured. A capture proves nothing else is getting out.

```bash
NIC=en5   # your active NIC; check with: route -n get default
sudo tcpdump -i $NIC -n -p -c 300 -U -w /tmp/dnscap.pcap 'port 53 or port 853'
```

In another terminal, force cold lookups:

```bash
dscacheutil -flushcache
for d in www.google.com mail.google.com gemini.google.com antigravity.google; do
  curl -s -o /dev/null -m 6 "https://$d/?r=$RANDOM"; done
curl -s -o /dev/null -m 6 "https://www.baidu.com/?r=$RANDOM"   # control
```

Read it:

```bash
sudo tcpdump -r /tmp/dnscap.pcap -n | grep '\.53 ' | awk '{print $3" -> "$5}' | sort | uniq -c | sort -rn
```

Pass: domestic DNS only. Anything mentioning the target hosts or `8.8.8.8`/`1.1.1.1` must be zero:

```bash
sudo tcpdump -r /tmp/dnscap.pcap -n | grep -icE 'google|8\.8\.8\.8|1\.1\.1\.1'   # expect 0
```

`-U` is mandatory: without it the file stays 0 bytes until the capture is killed.

## 6. IPv6 exposure

```bash
# global v6 addresses must be absent
ifconfig | grep inet6 | grep -v 'fe80\|::1\|fdfe\|fd7a'
# every service should report Off
for s in $(networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*'); do
  printf '%-14s ' "$s"; networksetup -getinfo "$s" 2>/dev/null | grep -i '^IPv6:'; done
```

Then confirm v6 genuinely cannot get out:

```bash
python3 - <<'PY'
import socket
for a in ['2606:4700:4700::1111','2001:4860:4860::8888']:
    s=socket.socket(socket.AF_INET6, socket.SOCK_STREAM); s.settimeout(5)
    try: s.connect((a,443)); print(f'  {a} connected <- still leaking')
    except Exception as e: print(f'  {a} {type(e).__name__} <- blocked')
    finally: s.close()
PY
```

`nc -z` is unreliable over IPv6 (it reports open for unreachable addresses). Use a python socket or a completed TLS handshake.

## 7. Regression

Confirm nothing got broken:

```bash
for u in https://www.baidu.com/ https://www.feishu.cn/; do
  printf '%-24s ' "$u"; curl -s -o /dev/null -m 8 -w '%{http_code} %{time_total}s\n' "$u"; done
curl -s -o /dev/null -m 5 -w 'lan %{http_code}\n' http://192.168.31.1/
/Applications/Tailscale.app/Contents/MacOS/Tailscale status | head -2
```

## Latency baseline

Normal values with a US Oregon node (RTT ~222 ms):

| Target | tls | total |
|---|---|---|
| mail.google.com | 0.25s | 0.50s |
| www.google.com | 0.26s | 0.56s |
| ssl.gstatic.com | 0.25s | 0.50s |

A `gstatic`-class host returning `000` with `total=5.0s` is a rule misclassifying it as direct (SKILL.md pitfall 1). Broadly higher than the table above means node distance — consider a JP node.
