# Production Runbook

Companion to `docs/runbook.md` (local `kind`). Assumes 2 real Kubernetes clusters
already exist, each with an Nginx ingress controller — cluster provisioning itself
(`eksctl`/Terraform, or `kubeadm` + `node_hardening` below if self-managed) is out of
scope.

## What's different from local

| | Local (`kind`) | Production |
|---|---|---|
| `cluster_platform_kubelet_insecure_tls` | `true` | `false` |
| `cluster_platform_pin_ingress_nginx_to_control_plane` | `true` | `false` |
| Failover LB | Single HAProxy container | Route53 health-check failover (+ optional keepalived VIP tier) |
| TLS | None | cert-manager + Let's Encrypt |
| Secrets | `kubectl create secret` | Secrets manager (below) |
| Monitoring | In-cluster, `emptyDir` | External, durable tier (below) |
| Deploy path | Manual `kubectl apply -k` | CI/CD (`ha-app.yml`) |

## 1. Prerequisites

- `kubectl` contexts for the real hot/standby clusters.
- Container registry (Docker Hub already wired, or ECR/GCR/ACR — update
  `k8s/base/kustomization.yaml`'s `images.newName`).
- Self-hosted GitHub Actions runner reachable from both clusters (GitHub-hosted runners
  can't reach a private-network cluster).
- Domain + Route53 hosted zone, for the failover topology in §7.

## 2. Node hardening (self-managed nodes only)

Skip for EKS/GKE/AKS managed node groups or Fargate.

```bash
# In inventory/{hot,standby}/hosts.ini: set real ansible_host IPs, ansible_user, ansible_ssh_private_key_file
cd ansible
ansible-playbook site.yml -i inventory/hot/hosts.ini --limit k8s_cluster
ansible-playbook site.yml -i inventory/standby/hosts.ini --limit k8s_cluster
```

OS patching, `ufw` firewall, sysctl hardening, admin tooling — see
`roles/node_hardening/tasks/main.yml`.

## 3. Platform layer

```bash
# In both inventory files: kube_context=<real context>, cluster_platform_kubelet_insecure_tls=false,
# cluster_platform_pin_ingress_nginx_to_control_plane=false
ansible-playbook site.yml -i inventory/hot/hosts.ini --limit local
ansible-playbook site.yml -i inventory/standby/hosts.ini --limit local
```

Same idempotent namespace/RBAC/quota/NetworkPolicy/metrics-server setup as local. `kind`'s
CNI doesn't enforce NetworkPolicy — a real policy-enforcing CNI (Calico/Cilium/AWS VPC
CNI) does, so verify enforcement explicitly (send traffic from an unauthorized pod and
confirm it's blocked) rather than assuming it works because it did in `kind`.

## 4. TLS (cert-manager + Let's Encrypt)

```bash
for ctx in <hot-context> <standby-context>; do
  kubectl --context "$ctx" apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
  kubectl --context "$ctx" -n cert-manager wait --for=condition=available deploy --all --timeout=120s
done
```

`ClusterIssuer` (both clusters):
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: <your-ops-email>
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

Then add a `tls:` block + `cert-manager.io/cluster-issuer: letsencrypt-prod` annotation to
`k8s/base/ingress.yaml`. Requires real DNS + public reachability for the HTTP-01
challenge — `kind` can't do this.

## 5. Secrets

Replace manual `kubectl create secret` with:
- **AWS Secrets Manager + External Secrets Operator** (if on AWS), or
- **Sealed Secrets** (cloud-agnostic, encrypted form safe to commit)

Covers: `dockerhub-creds`, `grafana-admin-credentials`, `letsencrypt-prod-key` (back it
up), and the CI/CD `KUBECONFIG_HOT`/`KUBECONFIG_STANDBY`/`DOCKERHUB_TOKEN` repo secrets.

## 6. Deploy

**Standard path**: push to `main` — `.github/workflows/ha-app.yml` runs test → build →
scan → push → deploy-standby (canary, smoke test) → deploy-hot, auto-rollback on smoke
test failure.

```bash
# break-glass only — bypasses the test gate and canary ordering
kubectl --context <hot-context> apply -k k8s/overlays/hot
kubectl --context <standby-context> apply -k k8s/overlays/standby
```

## 7. Failover topology

**Route53 health-check failover** — health check against each cluster's `/healthz`,
`PRIMARY`/`SECONDARY` routing policy. DNS-level failover; sufficient on its own for most
teams.

```bash
aws route53 create-health-check --caller-reference "$(date +%s)" --health-check-config \
  Type=HTTPS,ResourcePath=/healthz,FullyQualifiedDomainName=hot.yourdomain.com,Port=443,RequestInterval=10,FailureThreshold=2
# repeat for standby, then create PRIMARY/SECONDARY A/ALIAS records referencing each health check ID
```

**LB-tier redundancy** (optional) — `keepalived`/VRRP floating VIP across two LB
instances, so the LB itself isn't a SPOF. Needs real L2 adjacency — not implemented even
locally. Skip unless you need it; Route53 alone is what most teams run.

## 8. Monitoring

Local runs Prometheus/Loki/Grafana in-cluster on `emptyDir`. For production:
- Replace in-cluster Prometheus with an agent (Grafana Agent / OTel Collector)
  `remote_write`-ing to an external, durable tier.
- Self-host that tier (Thanos/Mimir/Cortex + Loki, S3-backed, outside both clusters) or
  use managed SaaS (Grafana Cloud, Amazon Managed Prometheus) — most teams pick SaaS
  since self-hosting the aggregation tier is itself an HA service to maintain.

## 9. Rollback / incident response

- **Automatic**: smoke test failure triggers `kubectl rollout undo`; `deploy-hot` is
  blocked entirely if `deploy-standby` failed.
- **Manual**: `kubectl -n app rollout undo deployment/ha-app --to-revision=<N>`
  (`rollout history` to list revisions).
- **Planned maintenance**: fail `hot`'s Route53 health check (or scale it to 0) before
  maintenance; confirm traffic actually shifted to `standby` in Grafana before proceeding.

## 10. Scaling for real load

`k8s/base`'s `50m`/`64Mi` requests and HPA `max: 6` are demo-scale defaults, not
load-tested. Before real traffic: load test, size `resources`/`hpa.maxReplicas` from
results, and enable cluster autoscaler so HPA scale-ups have nodes to land on.
