locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Public subnets only, no NAT gateway — a deliberate demo-only cost/simplicity call.
  # Real production would put nodes in private subnets behind a NAT gateway; skipped
  # here since this cluster's lifetime is "up for a few hours, then destroyed."
  public_subnet_cidrs = [cidrsubnet(var.vpc_cidr, 8, 0), cidrsubnet(var.vpc_cidr, 8, 1)]
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnet_cidrs
  private_subnets = [] # no private subnets — see note on public_subnet_cidrs above

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1" # required for ingress-nginx's NLB to land here
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  cluster_endpoint_public_access = true

  # Self-managed, not EKS-managed node groups — deliberate: this is what makes the nodes
  # plain, SSH-able EC2 instances that ansible/roles/node_hardening can actually run
  # against, same as it would on real bare-metal/EC2 in production.
  self_managed_node_groups = {
    default = {
      name           = "${var.cluster_name}-workers"
      instance_type  = var.node_instance_type
      min_size       = var.node_count
      max_size       = var.node_count
      desired_size   = var.node_count
      key_name       = aws_key_pair.node_ssh.key_name
      subnet_ids     = module.vpc.public_subnets
      capacity_type  = "ON_DEMAND"

      # Public IP so both SSH (node_hardening) and this demo's simplicity needs are met
      # without a bastion host. Not a production pattern — see main.tf note above.
      network_interfaces = [{
        associate_public_ip_address = true
        delete_on_termination       = true
      }]
    }
  }

  # RBAC mapping so Ansible/kubectl using your own AWS identity gets cluster-admin
  enable_cluster_creator_admin_permissions = true
}

resource "aws_key_pair" "node_ssh" {
  key_name   = "${var.cluster_name}-node-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "aws_security_group_rule" "node_ssh_ingress" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.ssh_ingress_cidr]
  security_group_id = module.eks.node_security_group_id
  description       = "SSH for Ansible node_hardening - scoped to ssh_ingress_cidr, not 0.0.0.0/0"
}
