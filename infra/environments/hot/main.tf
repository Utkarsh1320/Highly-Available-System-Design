terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Remote state: S3 + DynamoDB lock, created once by infra/bootstrap. Bucket name isn't
  # hardcoded here since it includes the AWS account ID — pass it at init time:
  #   terraform init -backend-config="bucket=$(cd ../../bootstrap && terraform output -raw state_bucket)"
  backend "s3" {
    key            = "hot/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "ha-assignment-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = "us-east-1"
}

module "hot_cluster" {
  source = "../../modules/eks-cluster"

  cluster_name         = "hot"
  region               = "us-east-1"
  vpc_cidr             = "10.10.0.0/16"
  node_instance_type   = var.node_instance_type
  node_count           = var.node_count
  ssh_public_key_path  = var.ssh_public_key_path
  ssh_ingress_cidr     = var.ssh_ingress_cidr
}

output "cluster_name" {
  value = module.hot_cluster.cluster_name
}

output "kubeconfig_command" {
  value = module.hot_cluster.kubeconfig_command
}

output "node_public_ips" {
  value = module.hot_cluster.node_public_ips
}
