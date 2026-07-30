# Architecture Design

## Overview

Two independent, identically-structured Kubernetes clusters — `hot` (active, us-east-1)
and `standby` (passive, us-west-2) — each running the app in an `app` namespace and a
Prometheus/Grafana/Loki stack in a `monitoring` namespace, both locked down by
NetworkPolicy (default-deny + explicit allows). Failover is DNS-driven: Route 53 picks
between the two regions by health check; within each region, a `keepalived`-backed
Virtual-IP in front of an active/backup HAProxy pair removes the load balancer itself as
a single point of failure.

## Request path

```
Client → Route 53 (health-check failover, primary=hot/backup=standby)
       → Virtual-IP (keepalived/VRRP, regional)
       → HAProxy (active/backup pair)
       → ingress-nginx
       → app namespace pods (NetworkPolicy allow, :3000)
```

Each cluster's control plane (API Server, etcd, Scheduler, Controller Manager) is
independent — there's no shared state between `hot` and `standby` at the Kubernetes
level, only at the data tier (`RDS-Primary` → `RDS-Replica`, async replication).

## Why two namespaces per cluster, not one

- **`app` namespace** — the workload. Default-deny NetworkPolicy, with explicit allows
  for ingress-nginx and the monitoring namespace, scoped to port 3000.
- **`monitoring` namespace** — Prometheus/Grafana/Loki, same default-deny posture. It
  scrapes *into* the app namespace (`scrape :3000`, its own NetworkPolicy allow) rather
  than the app pushing metrics out — the app namespace stays agnostic to who's watching it.

## Local vs. production

| | Local (this repo, `kind`) | Production (this diagram) |
|---|---|---|
| Clusters | Two `kind` clusters, one Docker host | Two real clusters, separate regions |
| Load balancer | Single HAProxy container, no VIP | `keepalived`-backed VIP + active/backup HAProxy pair per region |
| DNS failover | None — HAProxy alone decides hot vs. standby | Route 53 health-check failover between regions |
| NetworkPolicy | Applied, but `kind`'s default CNI doesn't enforce it | Enforced for real (EKS/GKE default CNI, or Calico/Cilium) |
| Database | None — app is stateless | RDS primary + cross-region replica, promotion via Aurora Global DB or manual runbook |
| TLS | None | Client-facing path encrypted end to end |

Everything above the load-balancer tier (clusters, namespaces, NetworkPolicy shape,
monitoring layout) is identical between local and production — only the LB/DNS layer and
the data tier change, since those are the two things a single-Docker-host demo genuinely
cannot reproduce.
