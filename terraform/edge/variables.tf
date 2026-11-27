variable "aws_region" {
  description = "AWS region the cluster and edge live in."
  type        = string
  default     = "ap-southeast-2"
}

variable "project" {
  description = "Platform prefix for names and tags."
  type        = string
  default     = "foundry"
}

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

variable "zone" {
  description = "Cloudflare zone. The certificate is a wildcard for one label under it."
  type        = string
  default     = "foonix.net"
}

variable "app_hostname" {
  description = "First app hostname to point at the ALB once alb_hostname is known."
  type        = string
  default     = "app1.foonix.net"
}

variable "alb_hostname" {
  description = "The ALB's DNS name, once the first Ingress has created it. Empty leaves the app record unmanaged; grey (DNS only) either way."
  type        = string
  default     = ""
}
