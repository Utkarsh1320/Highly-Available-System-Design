output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "region" {
  value = var.region
}

output "kubeconfig_command" {
  description = "Run this to add/refresh the kube_context this cluster's inventory expects"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}"
}

# The self-managed node group's ASG doesn't expose instance IPs as a direct module
# output, so look them up via the Name tag it propagates to instances. (Note:
# "eks:nodegroup-name" is an EKS-*managed*-nodegroup-only tag — doesn't apply here,
# since this is a self-managed group by design, see main.tf.)
data "aws_instances" "workers" {
  filter {
    name   = "tag:Name"
    values = ["${var.cluster_name}-workers"]
  }
  instance_state_names = ["running"]

  depends_on = [module.eks]
}

output "node_public_ips" {
  description = "Feed these into ansible/inventory/<cluster>/hosts.ini ansible_host values"
  value       = data.aws_instances.workers.public_ips
}
