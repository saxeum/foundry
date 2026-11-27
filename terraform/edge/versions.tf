terraform {
  required_version = ">= 1.17"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.7"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    key          = "edge/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Platform  = "foundry"
    }
  }
}

# The EKS API is private. This uses the kubeconfig `make eks-kubeconfig` writes:
# it dials 127.0.0.1:6443 through the SSM forward and carries the real hostname
# as tls-server-name, so the certificate validates over the tunnel.
# `make eks-tunnel` has to be running.
provider "helm" {
  kubernetes = {
    config_path    = pathexpand(var.kubeconfig)
    config_context = var.kube_context
  }
}
