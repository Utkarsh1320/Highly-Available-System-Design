#!/usr/bin/env bash
# Usage: scripts/new-service.sh <service-name> <port> [dockerhub-user] [source-dir]
#
# Example: scripts/new-service.sh orders-api 4000 utkarsh1320 services/orders-api

set -euo pipefail

SERVICE_NAME="${1:?Usage: $0 <service-name> <port> [dockerhub-user] [source-dir]}"
PORT="${2:?Usage: $0 <service-name> <port> [dockerhub-user] [source-dir]}"
DOCKERHUB_USER="${3:-utkarsh1320}"
SOURCE_DIR="${4:-services/${SERVICE_NAME}}"
HEALTHZ_PATH="${HEALTHZ_PATH:-/healthz}"
READYZ_PATH="${READYZ_PATH:-/readyz}"
METRICS_PATH="${METRICS_PATH:-/metrics}"

if [[ ! "$SERVICE_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  echo "error: service name must be lowercase alphanumeric with hyphens (valid k8s resource name)" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$REPO_ROOT/templates/service-scaffold"
K8S_DIR="k8s/services/$SERVICE_NAME"
DEST_K8S="$REPO_ROOT/$K8S_DIR"
WORKFLOW_DEST="$REPO_ROOT/.github/workflows/$SERVICE_NAME.yml"

if [[ -e "$DEST_K8S" ]]; then
  echo "error: $K8S_DIR already exists" >&2
  exit 1
fi
if [[ -e "$WORKFLOW_DEST" ]]; then
  echo "error: .github/workflows/$SERVICE_NAME.yml already exists" >&2
  exit 1
fi

echo "Scaffolding '$SERVICE_NAME' (port $PORT) at $K8S_DIR ..."
mkdir -p "$DEST_K8S"
cp -r "$TEMPLATE_DIR/k8s/." "$DEST_K8S/"
cp "$TEMPLATE_DIR/.github-workflow/SERVICE_NAME.yml" "$WORKFLOW_DEST"

substitute() {
  local file="$1"
  sed -i \
    -e "s|__SERVICE_NAME__|${SERVICE_NAME}|g" \
    -e "s|__PORT__|${PORT}|g" \
    -e "s|__IMAGE__|${SERVICE_NAME}|g" \
    -e "s|__DOCKERHUB_USER__|${DOCKERHUB_USER}|g" \
    -e "s|__SOURCE_DIR__|${SOURCE_DIR}|g" \
    -e "s|__K8S_DIR__|${K8S_DIR}|g" \
    -e "s|__HEALTHZ_PATH__|${HEALTHZ_PATH}|g" \
    -e "s|__READYZ_PATH__|${READYZ_PATH}|g" \
    -e "s|__METRICS_PATH__|${METRICS_PATH}|g" \
    "$file"
}

find "$DEST_K8S" -type f | while read -r f; do substitute "$f"; done
substitute "$WORKFLOW_DEST"

cat <<EOF

Done. Created:
  $K8S_DIR/base/            — Deployment, Service, ConfigMap, HPA, PDB, Ingress, NetworkPolicy
  $K8S_DIR/overlays/hot/    — host: ${SERVICE_NAME}.hot.local
  $K8S_DIR/overlays/standby/ — host: ${SERVICE_NAME}.standby.local
  .github/workflows/${SERVICE_NAME}.yml — CI/CD, calls the shared service-deploy.yml

Before this actually deploys:
  1. Write your app's Dockerfile with a 'runtime' build target (see app/Dockerfile
     for the pattern this platform's pipeline expects).
  2. Find your image's non-root UID/GID (docker run --rm ${SERVICE_NAME}:local id)
     and fill in runAsUser/runAsGroup in $K8S_DIR/base/deployment.yaml —
     without it, runAsNonRoot will fail at deploy time.
  3. Build + push once manually to seed docker.io/${DOCKERHUB_USER}/${SERVICE_NAME}:v1
     (kustomize's images.newTag in $K8S_DIR/base/kustomization.yaml expects
     that tag to already exist).
  4. Expose ${METRICS_PATH} on port ${PORT} if you want Prometheus data —
     it's auto-discovered via the prometheus.io/* annotations already set
     on the Deployment, no platform config to touch.
  5. If your service calls anything beyond DNS (a database, another internal
     service), add an egress rule to $K8S_DIR/base/networkpolicy.yaml —
     it currently only allows DNS egress by default.

This service shares the existing 'app' namespace, RBAC, and ResourceQuota —
see docs/design-decisions-qa.md for why, and the limits already in place.
EOF
