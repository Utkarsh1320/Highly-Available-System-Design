variable "cluster_name" {
  description = "EKS cluster name (e.g. hot, standby) — matches the Ansible inventory / kube_context naming"
  type        = string
}

variable "region" {
  description = "AWS region for this cluster (us-east-1 for hot, us-west-2 for standby)"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS control plane version"
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "CIDR for this cluster's VPC — kept distinct per region so there's no overlap if ever peered"
  type        = string
}

variable "node_instance_type" {
  description = "Self-managed worker node instance type"
  type        = string
  default     = "t3.small"
}

variable "node_count" {
  description = "Number of self-managed worker nodes (1 for the demo — real prod would be >=2 per cluster for the PDB to mean anything)"
  type        = number
  default     = 1
}

variable "ssh_public_key_path" {
  description = "Path to the local SSH public key — imported into AWS so node_hardening can reach the node"
  type        = string
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH into worker nodes. Set to your own IP/32 before applying, not 0.0.0.0/0."
  type        = string
}
