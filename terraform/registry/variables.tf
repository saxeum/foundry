variable "aws_region" {
  description = "AWS region for the ECR repositories."
  type        = string
  default     = "ap-southeast-2"
}

variable "project" {
  description = "Platform prefix for names and tags."
  type        = string
  default     = "foundry"
}

variable "github_owner" {
  description = "GitHub owner in the OIDC subject. The app repos live under it."
  type        = string
  default     = "saxeum"
}

variable "apps" {
  description = "Apps with image repositories. Adding an app is a platform PR: one entry here, then the onboarding steps."
  type        = list(string)
  default     = ["app1"]
}
