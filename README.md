# Highly Available System Design

A hot/standby high-availability platform for deploying developer services on
Kubernetes: two independent, mirrored clusters across regions, DNS + load-balancer
failover between them, and the automation (Ansible, CI/CD, NetworkPolicy, monitoring)
needed to run and onboard services onto it safely.

![Architecture](./architectural%20diagram/diagram-export-7-30-2026-2_09_45-PM.svg)

## What's here

| Path | What it is |
|---|---|
| `app/` | The example backend service (Express) — health/ready/metrics endpoints, multistage Dockerfile |
| `k8s/` | Kustomize manifests (base + hot/standby overlays) — Deployment, Service, HPA, PDB, Ingress, NetworkPolicy, monitoring stack |
| `ansible/` | `node_hardening` (OS patching/firewall for real servers) and `cluster_platform` (namespaces, RBAC, quotas, NetworkPolicy, metrics-server) |
| `failover/` | HAProxy config — active-health-check failover between the two clusters, verified live |
| `.github/workflows/` | Reusable CI/CD pipeline (test → scan → build → canary deploy to standby → deploy to hot), plus a thin caller per service |
| `scripts/new-service.sh` | Scaffolds a new service's manifests + CI/CD caller from `templates/service-scaffold/` |
| `docs/` | Design docs, runbooks, and the failover/network-security write-ups (see below) |

## Docs

- [`docs/architecture-design.md`](docs/architecture-design.md) — the design behind the diagram above, local-vs-production, cost trade-offs
- [`docs/failover-mechanism.md`](docs/failover-mechanism.md) — how failover actually works, verified live
- [`docs/network-and-security.md`](docs/network-and-security.md) — what's implemented vs. required for production
- [`docs/runbook.md`](docs/runbook.md) — run it locally on `kind`
- [`docs/production-runbook.md`](docs/production-runbook.md) — deploy it for real

## Quick start (local)

```bash
kind create cluster --config kind-hot-config.yaml
kind create cluster --config kind-standby-config.yaml
# then follow docs/runbook.md from step 3
```
