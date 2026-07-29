# Production Runbook

Companion to `docs/runbook.md` (local `kind` setup) — this is the same platform against
**real infrastructure**. this runbook starts from
"2 Kubernetes clusters already exist, each with an Nginx ingress controller configured"
— it does not cover provisioning the clusters themselves (that's `eksctl`/Terraform, or
`kubeadm` + the `node_hardening` role below if self-managed).

## What's different from the local setup

| | Local (`kind`) | Production |
|---|---|---|
| Clusters | `kind`, single Docker host | Real managed (EKS/GKE/AKS) or self-managed clusters |
| `cluster_platform_kubelet_insecure_tls` | `true` | `false` — real kubelet certs are properly signed |
| `cluster_platform_pin_ingress_nginx_to_control_plane` | `true` | `false` — a real cloud LB routes to ingress-nginx correctly regardless of node placement |
| Failover LB | Single HAProxy container | Route53 health-check failover + a real LB tier (see below) |
| TLS | None / self-signed | cert-manager + Let's Encrypt (real ACME) |
| Secrets | `kubectl create secret` by hand | A real secrets manager (below) |
| Monitoring | Per-cluster Prometheus/Loki, `emptyDir` | External, durable tier (below) — see `docs/design-decisions-qa.md` for the full trade-off |
| Deploy path | Manual `kubectl apply -k` | CI/CD pipeline (`.github/workflows/ha-app.yml`) |

## 1. Prerequisites

- `kubectl` contexts for both clusters (`kubectl config get-contexts`), pointed at the
  real hot/standby clusters — not `kind-hot`/`kind-standby`.
- A container registry (Docker Hub, as already wired, or ECR/GCR/ACR — update
  `k8s/base/kustomization.yaml`'s `images.newName` if switching).
- A self-hosted GitHub Actions runner on a machine with network access to both clusters
  (VPN into the VPC, or run it inside the cluster's network). GitHub-hosted runners
  cannot reach a private-network production cluster.
- A registered domain + Route53 hosted zone (or your DNS provider's equivalent), if
  implementing the failover topology below for real.

## 2. Node-level hardening (self-managed nodes only)

Skip this section entirely for EKS/GKE/AKS managed node groups or Fargate — the cloud
provider owns this layer. For self-managed EC2/VM worker nodes:

```bash
cd ansible
# Edit inventory/hot/hosts.ini and inventory/standby/hosts.ini:
#   - replace the placeholder ansible_host IPs with real node IPs
#   - set ansible_user / ansible_ssh_private_key_file to match your real access
#   - remove [local] localhost / kube_context — not used by this role

ansible-playbook site.yml -i inventory/hot/hosts.ini --limit k8s_cluster
ansible-playbook site.yml -i inventory/standby/hosts.ini --limit k8s_cluster
```

Applies OS security patches, firewall rules (`ufw`), sysctl hardening, and installs
admin tooling (`kubectl`/`helm`). See `roles/node_hardening/tasks/main.yml` for the
full list.

## 3. Platform layer

```bash
# In both inventory files, set:
#   kube_context=<your real hot/standby context>
#   cluster_platform_kubelet_insecure_tls=false
#   cluster_platform_pin_ingress_nginx_to_control_plane=false

ansible-playbook site.yml -i inventory/hot/hosts.ini --limit local
ansible-playbook site.yml -i inventory/standby/hosts.ini --limit local
```

Same idempotent namespace/RBAC/quota/NetworkPolicy/metrics-server setup as local — the
only change is the two kind-only flags flipping off. **Note**: kind's default CNI
(`kindnetd`) doesn't enforce NetworkPolicy at all — on a real cluster with a
policy-enforcing CNI (Calico, Cilium, AWS VPC CNI, GKE's default), these NetworkPolicies
actually take effect for the first time. Verify this explicitly after applying (send
traffic from an unauthorized pod/namespace and confirm it's actually blocked) rather
than assuming it "just works" because it worked in kind.

## 4. TLS (cert-manager + Let's Encrypt)

Not yet built into the Ansible role — these are the manual/scriptable steps for a real
deployment. (Local `kind` can't do real ACME validation since it has no public DNS to
prove domain ownership — a self-signed private CA is the local equivalent, a materially
different setup, not just this with a flag flipped.)

```bash
# Install cert-manager (both clusters)
for ctx in <hot-context> <standby-context>; do
  kubectl --context "$ctx" apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
  kubectl --context "$ctx" -n cert-manager wait --for=condition=available deploy --all --timeout=120s
done
```

`ClusterIssuer` (apply to both clusters, same manifest):
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

Then add a `tls:` block to `k8s/base/ingress.yaml` (per-overlay host, matching the
existing `ha-app.hot.local`/`ha-app.standby.local` JSON6902 pattern) and the
`cert-manager.io/cluster-issuer: letsencrypt-prod` annotation — cert-manager then issues
and auto-renews the certificate against the real hostname once it's DNS-resolvable and
publicly reachable for the HTTP-01 challenge.

## 5. Secrets

Local setup uses `kubectl create secret` with a locally-generated password — fine for a
demo, not for production. Use one of:
- **AWS Secrets Manager + External Secrets Operator** (if on AWS) — secrets live in
  Secrets Manager, ESO syncs them into Kubernetes `Secret` objects, never touch
  `kubectl create secret` by hand again.
- **Sealed Secrets** (cloud-agnostic) — encrypt secrets client-side, commit the encrypted
  form to git safely, the in-cluster controller decrypts on apply.

Either way, replace: `dockerhub-creds` (image pull), `grafana-admin-credentials`,
`letsencrypt-prod-key` (created automatically by cert-manager, but back it up), and the
CI/CD `KUBECONFIG_HOT`/`KUBECONFIG_STANDBY`/`DOCKERHUB_TOKEN` GitHub repo secrets.

## 6. Deploy

**Standard path**: push to `main` — `.github/workflows/ha-app.yml` handles test → build
→ push → deploy-standby (canary) → deploy-hot, with automatic rollback if the post-deploy
smoke test fails. This is the path that should be used day-to-day; manual `kubectl apply
-k` is the break-glass fallback, not the norm, since it bypasses the test gate and the
standby-first canary ordering.

```bash
# break-glass only:
kubectl --context <hot-context> apply -k k8s/overlays/hot
kubectl --context <standby-context> apply -k k8s/overlays/standby
```

## 7. Failover topology

The local setup uses a single HAProxy container as a stand-in for the architecture
diagram's full LB tier. Production should implement the real thing:

**Route53 health-check failover** — a health check against each cluster's `/healthz`
(through its real ingress endpoint), with a Route53 failover routing policy (`PRIMARY`
→ hot, `SECONDARY`→ standby) on the record clients actually resolve. This is DNS-level
failover — no HAProxy needed at all if this is your only failover layer, since clients
re-resolve DNS and land directly on whichever cluster is currently healthy.

```bash
aws route53 create-health-check --caller-reference "$(date +%s)" --health-check-config \
  Type=HTTPS,ResourcePath=/healthz,FullyQualifiedDomainName=hot.yourdomain.com,Port=443,RequestInterval=10,FailureThreshold=2
# repeat for standby, then create PRIMARY/SECONDARY A/ALIAS records referencing each health check ID
```

(Or via Ansible's `amazon.aws` collection — `route53_health_check` + `route53` modules —
if you want this managed alongside the rest of the platform config rather than a one-off
CLI/console setup.)

**LB-tier redundancy** (optional, matches the diagram's "active/backup NGINX" more
literally) — two LB instances (HAProxy or nginx) with `keepalived`/VRRP providing a
floating Virtual IP between them, so the LB layer itself isn't a single point of failure.
Not implemented here even as a local demo — it needs real L2 network adjacency that
doesn't translate to a single-Docker-host setup. If you don't need this extra layer,
Route53 health-check failover alone (pointing directly at each cluster's ingress LB) is
sufficient and is what most teams actually run.

## 8. Monitoring

Local setup runs a full Prometheus/Loki/Grafana stack *inside each cluster*, `emptyDir`
storage (lost on restart). For production, see `docs/design-decisions-qa.md`'s
observability section for the full reasoning; summary:
- Replace in-cluster Prometheus with a lightweight agent (Grafana Agent / OpenTelemetry
  Collector) `remote_write`-ing to an external, durable tier.
- Either self-host that tier (Thanos/Mimir/Cortex + Loki distributed, S3-backed, running
  *outside* both app clusters so it survives either one dying) or use a managed SaaS
  (Grafana Cloud, Amazon Managed Prometheus + Grafana) — the latter is what most teams
  actually choose, since self-hosting the aggregation tier is itself a production service
  you now have to keep highly available.

## 9. Rollback / incident response

- **Automatic**: `service-deploy.yml`'s smoke test failing triggers `kubectl rollout undo`
  automatically, and blocks `deploy-hot` entirely if `deploy-standby` failed
  (`needs: deploy-standby`).
- **Manual rollback**: `kubectl -n app rollout undo deployment/ha-app --to-revision=<N>`
  (`kubectl rollout history deployment/ha-app` to list revisions).
- **Manual failover for planned maintenance**: mark the Route53 health check for `hot` as
  failing (or temporarily lower `ha-app`'s replica count to 0 there) before doing
  maintenance — verify traffic has actually shifted to `standby` (check its own request
  rate in Grafana/Prometheus) before proceeding, don't assume the health check propagated
  instantly.

## 10. Scaling for real load

See `docs/design-decisions-qa.md`'s "Scaling to production" section for the full gap
analysis — in short: `k8s/base`'s `50m`/`64Mi` resource requests and the HPA's `max: 6`
are demo-scale defaults, not derived from real load testing. Before production traffic:
run real load tests, size `resources.requests/limits` and `hpa.maxReplicas` from the
results, and ensure cluster autoscaler is enabled so the HPA scaling up actually has
nodes to schedule onto.
