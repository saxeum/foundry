variable "aws_region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "ap-southeast-2"
}

variable "project" {
  description = "Platform prefix for names and tags."
  type        = string
  default     = "foundry"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.project))
    error_message = "project must be lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "github_oidc_host" {
  description = "The GitHub Actions OIDC host. The provider is account-global and already exists; this stack reads it rather than creating a second one."
  type        = string
  default     = "token.actions.githubusercontent.com"
}
