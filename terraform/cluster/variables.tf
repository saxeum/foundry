variable "aws_region" {
  description = "AWS region for the cluster."
  type        = string
  default     = "ap-southeast-2"
}

variable "project" {
  description = "Platform prefix for names and the state bucket."
  type        = string
  default     = "foundry"
}

variable "cluster_version" {
  description = "Kubernetes version. The newest standard-support EKS version ages out last."
  type        = string
  default     = "1.37"
}

variable "node_instance_types" {
  description = "Node instance types. t3.medium, because the observability stack is sized for the platform, not just the app, and the images are amd64."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Nodes to run. Two, so a rolling replacement has somewhere to schedule and a migration Job is never 'Too many pods'."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Nodes the group will not go below."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Nodes the group will not exceed. Three covers a rolling replacement with the observability stack on the same nodes."
  type        = number
  default     = 3
}
