terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Remote state: S3 + DynamoDB lock, created once by infra/bootstrap. Same bucket as
  # hot, different key — pass the bucket name at init time:
  #   terraform init -backend-config="bucket=$(cd ../../bootstrap && terraform output -raw state_bucket)"
  backend "s3" {
    key            = "standby/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "ha-assignment-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = "us-west-2"
}

module "standby_cluster" {
  source = "../../modules/eks-cluster"

  cluster_name        = "standby"
  region              = "us-west-2"
  vpc_cidr            = "10.20.0.0/16"
  node_instance_type  = var.node_instance_type
  node_count          = var.node_count
  ssh_public_key_path = var.ssh_public_key_path
  ssh_ingress_cidr    = var.ssh_ingress_cidr
}

output "cluster_name" {
  value = module.standby_cluster.cluster_name
}

output "kubeconfig_command" {
  value = module.standby_cluster.kubeconfig_command
}

output "node_public_ips" {
  value = module.standby_cluster.node_public_ips
}
