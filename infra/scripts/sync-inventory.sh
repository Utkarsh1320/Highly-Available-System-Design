#!/usr/bin/env bash
# Usage: infra/scripts/sync-inventory.sh <hot|standby>
#
# Reads this environment's Terraform output and prints the ansible_host lines to paste
# into ansible/inventory/<cluster>/hosts.ini — doesn't edit the file automatically since
# hosts.ini also carries hand-written group/var structure worth reviewing, not just IPs.

set -euo pipefail

CLUSTER="${1:?Usage: $0 <hot|standby>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_DIR="$REPO_ROOT/infra/environments/$CLUSTER"

cd "$ENV_DIR"
IPS=$(terraform output -json node_public_ips | jq -r '.[]')

echo "# Paste into ansible/inventory/$CLUSTER/hosts.ini, replacing the placeholder ansible_host values:"
i=1
for ip in $IPS; do
  echo "${CLUSTER}-worker${i} ansible_host=${ip}"
  i=$((i + 1))
done

echo
echo "# Also update [all:vars] in that file:"
echo "kube_context=${CLUSTER}"
echo "cluster_platform_kubelet_insecure_tls=false"
echo "cluster_platform_pin_ingress_nginx_to_control_plane=false"
echo
echo "# And run this once to add the kube_context:"
terraform output -raw kubeconfig_command
