# Failover Mechanism

How traffic automatically moves from the hot cluster to the standby cluster when hot
fails, and back again when it recovers — implemented with HAProxy locally, with the
production equivalent described at the end.

## The mechanism

A single load balancer sits in front of both clusters and continuously health-checks
both. It never round-robins between them — one is always primary, one is always
standby, and it switches which one receives traffic based purely on health, not
manual intervention.

```
                    ┌──────────────┐
   client ───────▶  │   HAProxy    │
                    │ (active LB)  │
                    └──────┬───────┘
                 primary   │   backup
              ┌────────────┴────────────┐
              ▼                         ▼
        ┌───────────┐             ┌───────────┐
        │  hot       │             │  standby   │
        │  cluster   │             │  cluster   │
        └───────────┘             └───────────┘
```

Configuration lives in `failover/haproxy.cfg`:

```
backend ha_app_cluster
    http-request set-header Host ha-app.local

    option httpchk GET /healthz
    http-check send hdr Host ha-app.local
    http-check expect status 200
    default-server inter 2s fall 2 rise 2

    server hot     127.0.0.1:80   check
    server standby 127.0.0.1:8080 backup check
```

- **`option httpchk GET /healthz`** — an *active* health check: HAProxy proactively
  polls each backend's `/healthz` on its own schedule, independent of real client
  traffic. This is a deliberate choice over nginx's simpler passive-only failure
  detection (which only learns a backend is down after real requests to it start
  failing) — active checks catch the failure *before* a real user hits it.
- **`inter 2s fall 2 rise 2`** — checks every 2 seconds; 2 consecutive failures marks a
  backend down, 2 consecutive successes marks it back up. Worst-case detection time:
  ~4 seconds from actual failure to HAProxy noticing.
- **`backup`** on the `standby` server line — this is what makes it standby rather than
  a second active backend. HAProxy sends 100% of traffic to `hot` as long as it's
  healthy, and only starts sending to `standby` once `hot` is marked down. Traffic
  moves back to `hot` automatically the moment it's marked healthy again — no manual
  cutover, in either direction.
- **`option redispatch`** — if a request is already in flight to a backend that fails
  mid-request, HAProxy retries it against a different backend within the *same* client
  request, rather than returning an error. This is what makes failover invisible to an
  in-progress request, not just to the next one.
- **`http-request set-header Host ha-app.local`** — both clusters' Ingress resources
  answer on this shared hostname regardless of which is being hit, so HAProxy can
  address either one with the same header rather than needing per-backend routing
  logic.

## Verified behavior (not just configured — actually tested)

Stopped the `hot` cluster mid-session and polled through HAProxy. Every response
remained `200 OK` throughout — no client-visible failure at all, confirmed by HAProxy's
own request log tagging every single request as answered by `standby`:

```
127.0.0.1:39176 [...] public ha_app_cluster/standby 0/0/0/2/2 200 197 ...
127.0.0.1:39190 [...] public ha_app_cluster/standby 0/0/0/2/2 200 197 ...
```

Then resumed `hot`. HAProxy's own log shows the automatic failback:

```
Server ha_app_cluster/hot is UP, reason: Layer7 check passed, code: 200,
check duration: 2ms. 1 active and 1 backup servers online.
```

...and subsequent requests were tagged `ha_app_cluster/hot` again — traffic returned to
the primary with no manual action.

## Try it yourself

```bash
# confirm hot is serving
docker logs ha-failover --tail 3

# fail hot
docker stop hot-control-plane hot-worker
curl http://127.0.0.1:9000/healthz    # still 200, now from standby
docker logs ha-failover --tail 3      # shows ha_app_cluster/standby

# recover hot
docker start hot-control-plane hot-worker
# wait ~30s for hot's own cluster networking to stabilize, then:
docker logs ha-failover --tail 3      # shows ha_app_cluster/hot again
```

Live stats page: `http://localhost:8404/` — shows both backends' current state
(`UP`/`DOWN`) and which one is actively serving in real time.

## What this stands in for, and what it doesn't cover

This HAProxy setup is the local, testable equivalent of the "active/backup NGINX load
balancer" layer in the architecture diagram — it proves the *mechanism* (active health
checks, automatic cutover, automatic failback) genuinely works, end to end.

Two things it deliberately does not implement, both documented in
`docs/production-runbook.md`:

1. **DNS-level failover (Route53)** — the diagram's actual top layer. In production,
   Route53 health checks against each cluster's real endpoint drive a failover DNS
   record, so clients re-resolve directly to whichever cluster is healthy — no
   HAProxy instance required at all for this to work. HAProxy here is a stand-in
   because a real Route53 setup needs a real public domain, which a local demo doesn't
   have.
2. **LB-tier redundancy** — this single HAProxy container is itself a single point of
   failure. A real production LB tier would run two instances with `keepalived`/VRRP
   providing a floating Virtual IP between them, so the load balancer itself isn't a
   SPOF. Not implemented even as a local demo, since VRRP needs real L2 network
   adjacency that doesn't translate to a single-Docker-host setup — it would be closer
   to theater than a real test of the mechanism.

## A real bug this surfaced

Building this exposed a genuine, previously-hidden defect: the upstream `kind`-provider
ingress-nginx manifest (pinned to the unpinned `main` branch) was missing the
`ingress-ready` nodeSelector and control-plane toleration needed for the controller to
land on the node with kind's actual host port mapping. Every earlier verification in
this project had gone through `kubectl port-forward`, which happens to route around
exactly this class of bug — it only surfaced once HAProxy needed the real host ports
directly. Fixed as an idempotent Ansible task
(`cluster_platform_pin_ingress_nginx_to_control_plane`, kind-only), verified by
deliberately reverting the fix and confirming Ansible re-applies it automatically.
