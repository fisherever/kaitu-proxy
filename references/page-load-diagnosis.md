# Diagnosing a slow page through the tunnel

Use when someone reports a site feeling slow while single-request tests look healthy. The
browser is the only instrument that sees what the user sees: it negotiates HTTP/3, opens
dozens of connections at once, and reports per-resource protocol and timing.

## Why curl misleads

- Most `curl` builds have no `--http3`, so QUIC is never exercised. Check with `curl -V | grep HTTP3`
  before trusting any curl-based conclusion about page speed.
- A single request measures one connection. Page slowness is usually concurrency, protocol
  choice, or a resource class curl never fetches.
- Both facts together produce a confident wrong answer: small requests look fine while the
  page crawls.

## Procedure

1. Enable the network domain and defeat the cache, or the second load reports `median 0 ms`
   from memory cache and looks perfect:
   ```python
   cdp('Network.enable')
   cdp('Network.setCacheDisabled', cacheDisabled=True)
   goto_url('https://<site>/?cold=' + str(time.time()))
   wait_for_load(); time.sleep(4)
   ```

2. Read per-resource protocol and duration, then aggregate. This is the whole diagnosis:
   ```javascript
   (() => {
     const nav = performance.getEntriesByType('navigation')[0] || {};
     const r = performance.getEntriesByType('resource');
     const d = r.map(e => e.duration).sort((a,b)=>a-b);
     const proto = {};
     for (const e of r) { const p = e.nextHopProtocol || '?'; proto[p] = (proto[p]||0)+1; }
     const q = n => Math.round(d[Math.min(d.length-1, Math.floor(d.length*n))]||0);
     return JSON.stringify({dcl: Math.round(nav.domContentLoadedEventEnd||0),
       load: Math.round(nav.loadEventEnd||0), n: r.length,
       p50: q(0.5), p90: q(0.9), max: Math.round(d[d.length-1]||0), proto});
   })()
   ```

3. Name the slow resources and their hosts — the host pattern is the clue:
   ```javascript
   performance.getEntriesByType('resource')
     .map(e => [new URL(e.name).host, e.nextHopProtocol, Math.round(e.duration), e.transferSize||0])
     .sort((a,b)=>b[2]-a[2]).slice(0,8)
   ```

## Reading the result

| Observation | Meaning |
|---|---|
| `proto` dominated by `h3`, slowest resources 10-25 s, the rare `h2` resource fast | QUIC over the proxy's UDP path is broken. Reject UDP/443 (see below) |
| All h2, one host slow, others fine | Routing or that host's CDN. Check the rule that matched it |
| Every resource a uniform ~10 s, right after a config change | Stale fake-ip mappings from the reload, not a regression. Load again |
| p50 near 250 ms, p90 under 1 s, all h2 | Healthy for a ~200 ms RTT node. Stop optimising |
| `median 0 ms` | Served from cache. The test is void — disable the cache |

## The QUIC fix

First-position rule in `config.yaml`, then hot-reload:

```yaml
rules:
  - AND,((NETWORK,udp),(DST-PORT,443)),REJECT
```

Observed on a cold page load: p90 2937 ms -> 945 ms, slowest 18.9 s -> 0.96 s, full load
1.7 s, protocols 52 h3 / 1 h2 -> 0 h3 / 88 h2. Cost: everything that prefers QUIC (video,
some Google properties) falls back to TCP. That is the correct trade while the UDP path is
unusable.

Verify the rule is genuinely first via `/rules` — a reject placed after `MATCH` never fires.

## Cross-checks that do not need a browser

- `curl` to one large asset: healthy single-stream throughput but a slow page confirms the
  problem is per-connection/protocol, not bandwidth.
- Parallel curls to the same asset at 1 / 5 / 20 workers: near-linear aggregate scaling means
  the tunnel is fine under load, which again points at protocol rather than capacity.

## Do not

- Do not conclude "node distance" from a page that feels worse than its curl timings. Distance
  raises every request equally; it does not produce 25 s outliers next to 269 ms ones.
- Do not judge a config change on one sample. This link swings 0.6x-2.0x minute to minute;
  alternate configurations round by round and compare medians.
