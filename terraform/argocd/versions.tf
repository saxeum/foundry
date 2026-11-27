terraform {
  required_version = ">= 1.17"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    key          = "argocd/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

# The EKS API is private. This uses the kubeconfig `make eks-kubeconfig` writes:
# it dials 127.0.0.1:6443 through the SSM forward and carries the real hostname
# as tls-server-name. `make eks-tunnel` has to be running.
provider "helm" {
  kubernetes = {
    config_path    = pathexpand(var.kubeconfig)
    config_context = var.kube_context
  }
}
