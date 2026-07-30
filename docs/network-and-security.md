# Network and Security

## Implemented

- **Pod hardening** — non-root user, no privilege escalation, read-only root
  filesystem, all Linux capabilities dropped, `seccomp: RuntimeDefault`.
- **NetworkPolicies** — default-deny in both the `app` and `monitoring` namespaces,
  with explicit scoped allows: ingress-nginx → app, monitoring → app (metrics
  scraping), DNS egress, and a placeholder rule for external database egress.
- **RBAC** — developer access scoped to the `app` namespace only; Prometheus/Promtail
  service accounts scoped to `list`/`watch` pods, nothing else.
- **Node-level firewall** — deny-by-default `ufw`, only SSH, API server, kubelet, and
  the NodePort range open, scoped to the cluster's internal CIDR.
- **OS security patching** — automated via `unattended-upgrades`, applied and
  re-verified idempotently.
- **Private container registry** with `imagePullSecrets`, not a public image.
- **Secrets** kept out of git — created directly in-cluster, never committed.

## Required for production

- **TLS** — no encryption in transit yet. Plan (cert-manager + Let's Encrypt) is
  specified but not built.
- **Pod Security Standards** — no namespace-level admission control restricting what
  pod specs are allowed to run.
- **Cloud-level network segmentation** — no VPC subnet / security-group design between
  the load balancer, application, and database tiers.
- **Kubernetes API audit logging** — not enabled.
- **Rate limiting / WAF** at the ingress layer — no abuse or traffic-shaping
  protection.
- **Secrets manager** — secrets are created manually; no rotation or centralized
  management.
- **Real database network rule** — the egress rule for the database is a placeholder
  (no real endpoint exists yet).
