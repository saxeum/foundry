terraform {
  required_version = ">= 1.17"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.7"
    }
  }

  # No backend block, deliberately. This stack creates the S3 bucket every other
  # stack stores its state in, so it cannot store its own state there. The state
  # stays local, is gitignored, and is reconstructible by import if it is lost.
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
