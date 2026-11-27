variable "aws_region" {
  description = "AWS region for the VPC."
  type        = string
  default     = "ap-southeast-2"
}

variable "project" {
  description = "Platform prefix for names and tags."
  type        = string
  default     = "foundry"
}

variable "vpc_cidr" {
  description = "CIDR for the foundry VPC. Must not overlap godough's 10.42.0.0/16 or the default VPC's 172.31.0.0/16."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}
