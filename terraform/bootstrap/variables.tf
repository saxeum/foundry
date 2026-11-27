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
  description = "The GitHub Actions OIDC host. The URL is what the provider is keyed on, and AWS allows one provider per URL per account."
  type        = string
  default     = "token.actions.githubusercontent.com"
}

variable "manage_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider. Set false when the account already has one: the stack then reads it instead of creating a duplicate that fails with EntityAlreadyExists."
  type        = bool
  default     = true
}

variable "github_oidc_thumbprints" {
  description = "Thumbprints for the GitHub OIDC certificate chain. The first two are the historical DigiCert chain, kept for overlap; the last two are the current Let's Encrypt chain."
  type        = list(string)
  default = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
    "cbcfd09ce3cd22d99d94e58f92e9898fbee51a5e",
    "ab9d0263244dd0326eb67015705a667e79cfe998",
  ]
}
