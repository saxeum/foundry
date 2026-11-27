variable "kubeconfig" {
  description = "Kubeconfig written by make eks-kubeconfig. It dials the tunnel, so make eks-tunnel must be running."
  type        = string
  default     = "~/.kube/foundry"
}

variable "kube_context" {
  description = "Context to use in that kubeconfig."
  type        = string
  default     = "foundry-staging"
}

variable "namespace" {
  description = "Namespace Argo CD is installed into."
  type        = string
  default     = "argocd"
}

variable "chart_version" {
  description = "Pinned argo-cd chart version. A tag can move; the upgrade is a platform PR."
  type        = string
  default     = "10.20.0"
}
