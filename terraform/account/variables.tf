variable "aws_region" {
  description = "Region the account-level controls apply to. GuardDuty is regional; the trail is multi-region."
  type        = string
  default     = "ap-southeast-2"
}

variable "project" {
  description = "Platform prefix for names and tags."
  type        = string
  default     = "foundry"
}
