# Failover Mechanism

**Sole purpose**: prove that traffic moves from `hot` to `standby` automatically when
`hot` fails, and back again automatically when it recovers — no manual cutover, in
either direction.

## How it works

`failover/haproxy.cfg` actively health-checks both clusters and sends 100% of traffic to
`hot`; `standby` only receives traffic once `hot` fails, and traffic returns the moment
`hot` recovers:

```
backend ha_app_cluster
    option httpchk GET /healthz
    default-server inter 2s fall 2 rise 2
    server hot     127.0.0.1:80   check
    server standby 127.0.0.1:8080 backup check
```

- **Active health check** (`httpchk`), not passive — HAProxy detects failure before a
  real user hits it, rather than learning from failed user requests.
- **`inter 2s fall 2 rise 2`** — ~4s worst-case detection time in either direction.
- **`backup`** — the entire mechanism; without it this is round-robin, not failover.
- **`option redispatch`** (in the full config) — retries an in-flight request against the
  other backend instead of failing it, so failover is invisible mid-request too.

## Verified live, not just configured

Stopped `hot` mid-session; every request stayed `200 OK`, HAProxy's own log confirms
every one was answered by `standby`:
```
... public ha_app_cluster/standby 0/0/0/2/2 200 197 ...
```
Resumed `hot`; HAProxy's log confirms automatic failback:
```
Server ha_app_cluster/hot is UP ... 1 active and 1 backup servers online.
```

## Try it yourself

```bash
docker stop hot-control-plane hot-worker
curl http://127.0.0.1:9000/healthz    # still 200, now from standby
docker start hot-control-plane hot-worker
docker logs ha-failover --tail 3      # back to ha_app_cluster/hot
```
Live view: `http://localhost:8404/`.


