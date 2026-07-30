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

## Cost decisions and trade-offs

| Decision | Cheaper alternative | Why not the cheaper option |
|---|---|---|
| Self-hosted `keepalived` + HAProxy | Cloud-managed ALB/NLB (no VIP/failover to run yourself) | Bare-metal has no managed LB at all; on cloud, the managed LB is usually the *better* choice — this pattern exists specifically for the bare-metal case, not as a cost optimization |
| Standby at **equal** capacity to hot | Scaled-down/cold standby (fewer replicas until failover) | Chosen deliberately despite ~2x compute cost — a cold standby means HPA has to scale up *during* an active incident, adding delay exactly when it's least affordable |
| Route53 standard health checks (30s interval) | N/A — this *is* the cheaper tier already | Fast health checks (10s) cost more per check; standard is the default here since a few extra seconds of detection time is an acceptable trade for lower cost |
| Per-cluster Prometheus/Loki, ephemeral storage | Managed observability SaaS (Grafana Cloud, Amazon Managed Prometheus) | Cheaper to self-host at small scale; the trade-off flips at real scale, where self-hosting the aggregation tier becomes its own HA service to maintain — see `docs/design-decisions-qa.md`'s observability section |
| Cross-region RDS: standard read replica | Aurora Global Database (faster, more automated failover) | Standard replica is cheaper but promotion is a manual/scripted step, not automatic — an explicit availability-vs-cost trade, not a default |
| `ubuntu-slim` runner for the CI `test` job | N/A — already the cost-optimized choice | `build-and-push` must stay on standard `ubuntu-latest`, since `ubuntu-slim` can't run Docker-in-Docker — the cheaper runner is only usable where the job's actual requirements allow it |
| Self-managed nodes + `node_hardening` Ansible role | EKS/GKE managed node groups | Self-managed is cheaper per-node but shifts patching/hardening work onto you; `node_hardening` exists specifically to carry that cost in engineering time instead of cloud premium |

The general pattern: every trade-off above was made deliberately, not defaulted to —
each row picks availability/speed over cost in the places that matter most during an
actual incident (standby capacity, LB tier redundancy), and picks cost over marginal
speed/automation everywhere the difference is small (health check interval, CI runner
size, replica promotion).
