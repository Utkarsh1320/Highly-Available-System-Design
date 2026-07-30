# Runbook — running this locally on your own machine

Everything here targets two local `kind` clusters (`hot`, `standby`) standing in for
"2 k8s clusters already deployed" per the assignment's assumption. Real production
clusters skip steps 1–3 entirely (no `kind`, no inotify tuning, no manual node pinning)
and start from step 4.

## Prerequisites

```bash
# Docker, kind, kubectl — install via your OS package manager if missing
docker --version
kind --version
kubectl version --client
```

Python 3 is only needed if you want to run Ansible locally instead of via Docker
(instructions below use Docker so nothing extra is required).

## 1. Raise inotify limits (one-time, host-level)

Running two multi-pod `kind` clusters plus normal `kubectl exec`/`port-forward` usage
exhausts Linux's default inotify limits (`max_user_instances: 128` is too low) — this
manifests as `kube-proxy`/CoreDNS crash-looping with `"too many open files"`.

```bash
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=1024
# persist across reboots:
echo -e "fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=1024" | sudo tee /etc/sysctl.d/99-kind.conf
```

## 2. Create the clusters

```bash
kind create cluster --config kind-hot-config.yaml
kind create cluster --config kind-standby-config.yaml
kubectl config get-contexts   # confirms kind-hot / kind-standby
```

`hot` maps host ports 80/443, `standby` maps 8080/8443 — both run on the same Docker
host, so they can't share a port.

**Memory note**: two clusters plus the monitoring stack is heavy. If you hit memory
pressure, work with one cluster at a time:
```bash
docker stop hot-control-plane hot-worker        # pause, keeps state
docker start standby-control-plane standby-worker  # resume the other
```

## 3. Install ingress-nginx on each cluster

```bash
for ctx in kind-hot kind-standby; do
  kubectl --context "$ctx" apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
  kubectl --context "$ctx" -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=180s
done
```

The `main`-branch kind-provider manifest above is missing the `ingress-ready`
nodeSelector + control-plane toleration that pin the controller to the node with the
actual host port mapping — without it, the controller can schedule onto the worker node
and become unreachable. This is fixed automatically by the Ansible step below
(`cluster_platform_pin_ingress_nginx_to_control_plane`, kind-only, idempotent) — no
manual patch needed.

## 4. Configure the platform layer (Ansible)

```bash
cd ansible
python3 -m venv .venv && source .venv/bin/activate   # first time only
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml

ansible-playbook site.yml -i inventory/hot/hosts.ini --limit local
ansible-playbook site.yml -i inventory/standby/hosts.ini --limit local
cd ..
```

This creates the `app`/`monitoring` namespaces, ResourceQuota/LimitRange, developer RBAC,
NetworkPolicies for the `monitoring` namespace, and installs+patches `metrics-server`
for kind's self-signed kubelet certs. Safe to re-run — idempotent.

## 5. Docker Hub pull secret (per cluster)

Reuses your existing `docker login` session, no need to retype credentials:

```bash
for ctx in kind-hot kind-standby; do
  kubectl --context "$ctx" -n app create secret generic dockerhub-creds \
    --from-file=.dockerconfigjson="$HOME/.docker/config.json" \
    --type=kubernetes.io/dockerconfigjson
done
```

## 6. Deploy the app

```bash
kubectl --context kind-hot apply -k k8s/overlays/hot
kubectl --context kind-standby apply -k k8s/overlays/standby
kubectl --context kind-hot -n app rollout status deploy/ha-app --timeout=90s
kubectl --context kind-standby -n app rollout status deploy/ha-app --timeout=90s
```

If this fails with `dial tcp ...:443: connect: connection refused` against
`ingress-nginx-controller-admission`, the admission webhook just isn't ready yet — wait
~15s and re-run the same `apply -k` command.

## 6b. Onboarding a second service (optional)

Don't hand-write manifests for a new service — scaffold them:

```bash
./scripts/new-service.sh orders-api 4000 <your-dockerhub-user>
```

Generates `k8s/services/orders-api/` (Deployment/Service/ConfigMap/HPA/PDB/Ingress/
NetworkPolicy, hot+standby overlays — same pattern as `ha-app`, sharing the existing
`app` namespace/RBAC/quota) plus `.github/workflows/orders-api.yml`, a thin caller into
the shared `service-deploy.yml` reusable pipeline. The script prints the exact follow-up
steps (Dockerfile, non-root UID, first image push). No Prometheus config to touch —
scraping is annotation-driven service discovery, any new service is picked up
automatically as long as its Deployment carries `prometheus.io/scrape: "true"`.

## 7. Deploy monitoring (Prometheus + Loki + Promtail + Grafana)

```bash
for ctx in kind-hot kind-standby; do
  kubectl --context "$ctx" apply -k k8s/monitoring/overlays/${ctx#kind-}

  GRAFANA_PW=$(openssl rand -base64 18)
  kubectl --context "$ctx" -n monitoring create secret generic grafana-admin-credentials \
    --from-literal=username=admin --from-literal=password="$GRAFANA_PW"
  echo "$ctx Grafana password: $GRAFANA_PW"
done
```

Save those passwords — they're not stored anywhere else.

## 8. Failover (HAProxy)

Needs both clusters reachable at once (host ports 80 for hot, 8080 for standby):

```bash
docker rm -f ha-failover >/dev/null 2>&1
docker run -d --name ha-failover --network host \
  -v "$(pwd)/failover/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
  haproxy:2.9
```

Stats page: `http://localhost:8404/`. Traffic: `http://localhost:9000/`.

## 9. Verify everything

```bash
# app, direct
curl -H "Host: ha-app.local" http://127.0.0.1/healthz      # hot
curl -H "Host: ha-app.local" http://127.0.0.1:8080/healthz # standby

# through the failover LB
curl http://127.0.0.1:9000/healthz

# HPA / metrics-server
kubectl --context kind-hot -n app get hpa

# Prometheus targets (should all show "up")
kubectl --context kind-hot -n monitoring exec deploy/prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets' | grep -o '"health":"[a-z]*"'
```

Grafana: `http://localhost:3000` via `kubectl -n monitoring port-forward svc/grafana 3000:3000`, or `http://grafana.hot.local/` after adding it to `/etc/hosts`.

## After a `docker stop`/`docker start` pause-resume cycle

`kind` node pause/resume doesn't reliably restore `kube-proxy`/CNI iptables state.
If pods can't reach the API server or each other after resuming a cluster:

```bash
kubectl --context <ctx> -n kube-system delete pod -l k8s-app=kube-proxy
kubectl --context <ctx> -n kube-system delete pod -l app=kindnet
kubectl --context <ctx> -n ingress-nginx delete pod -l app.kubernetes.io/component=controller
```

Wait ~20s between each and re-check `kubectl get pods -A` before moving on.

If that doesn't fix it either (symptoms: `kube-proxy` looks healthy but Service routing
is still broken, or `ingress-nginx` is `Running` but nothing is listening on host port
80/443 even after recreating the pod), the cluster itself needs rebuilding — repeat
steps 2 through 7 for just that one cluster (`kind delete cluster --name hot`, then
recreate and redeploy). Nothing in that flow is special-cased for a first-time create
vs. a rebuild — the Ansible step applies
`cluster_platform_pin_ingress_nginx_to_control_plane` idempotently either way, no manual
patch needed.

## CI/CD (separate from this local setup)

`.github/workflows/ha-app.yml` (and any generated `<service>.yml`) needs repo secrets
(`DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `KUBECONFIG_HOT`, `KUBECONFIG_STANDBY`) and a
self-hosted GitHub Actions runner registered on a machine that can reach these clusters —
GitHub-hosted runners can't reach local `kind` clusters. Not required to just run
everything locally as above.

## Tearing down

```bash
docker rm -f ha-failover
kind delete cluster --name hot
kind delete cluster --name standby
```
