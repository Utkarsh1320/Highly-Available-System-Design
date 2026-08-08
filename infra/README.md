# Infra (Terraform)

Provisions the 2 real EKS clusters (`hot` in `us-east-1`, `standby` in `us-west-2`) that
the rest of this repo assumes already exist — this replaces `kind` for a real cloud
demonstration. Self-managed node groups (plain EC2, not EKS-managed) deliberately, so
`ansible/roles/node_hardening` has real, SSH-able servers to configure.

```
infra/
  modules/eks-cluster/   # reusable module: VPC + EKS control plane + self-managed nodegroup
  environments/hot/      # us-east-1, calls the module
  environments/standby/  # us-west-2, calls the module
  scripts/sync-inventory.sh
```

## One-time setup

```bash
# SSH key node_hardening will use
ssh-keygen -t ed25519 -f ~/.ssh/ha-assignment -N ""

# Your own IP, for the tfvars files below — don't leave this as 0.0.0.0/0
curl -s ifconfig.me

cp infra/environments/hot/terraform.tfvars.example infra/environments/hot/terraform.tfvars
cp infra/environments/standby/terraform.tfvars.example infra/environments/standby/terraform.tfvars
# edit both, set ssh_ingress_cidr to <your-ip>/32
```

## Bootstrap remote state (once, ever)

Creates the S3 bucket + DynamoDB lock table that `hot`/`standby` store their state in.
Its own state stays local — see the comment in `bootstrap/main.tf` for why that's fine
here and not a double standard.

```bash
cd infra/bootstrap
terraform init
terraform apply
```

## Provision

```bash
cd infra/environments/hot
terraform init -backend-config="bucket=$(cd ../../bootstrap && terraform output -raw state_bucket)"
terraform apply

cd ../standby
terraform init -backend-config="bucket=$(cd ../../bootstrap && terraform output -raw state_bucket)"
terraform apply
```

Each takes ~15-20 min (EKS control plane creation is the slow part). Can run in two
terminals in parallel.

## Wire up Ansible

```bash
../../scripts/sync-inventory.sh hot       # prints ansible_host lines + kube_context vars
../../scripts/sync-inventory.sh standby
```

Paste the printed values into `ansible/inventory/{hot,standby}/hosts.ini`, run the
`aws eks update-kubeconfig` command it prints for each, then continue with
`docs/production-runbook.md` from step 2 onward (ingress-nginx → `cluster_platform` →
app deploy → CI/CD → failover demo).

## Teardown

```bash
cd infra/environments/hot && terraform destroy
cd ../standby && terraform destroy
```

Run this at the end of every session — the EKS control plane bills hourly regardless of
node state, there's no "pause" for it (see the session notes on why we rebuild fresh each
time instead of stopping/starting nodes). Leave `bootstrap/` alone — the state bucket and
lock table are cheap to keep and are what let you re-`apply` cleanly next session without
re-bootstrapping.

## Why these specific calls

- **Remote state (S3 + DynamoDB lock), bootstrapped separately** — real production
  practice, not a demo shortcut: `hot`/`standby` share one bucket (different keys) so
  state survives a lost laptop and a second person could safely `apply` without state
  corruption. The bootstrap config itself stays on local state, since it can't depend on
  the backend it's creating, and changes rarely enough that this isn't a real risk.
- **Public subnets, no NAT gateway** — cost/simplicity call for a short-lived demo. Real
  production puts worker nodes in private subnets behind a NAT gateway; skipped here to
  avoid the NAT gateway's own hourly cost for an environment that won't outlive the day.
- **Self-managed, not EKS-managed, node groups** — the one choice that isn't a shortcut:
  this is what makes `node_hardening` prove something real instead of having nothing to
  run against.
