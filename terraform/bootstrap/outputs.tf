output "state_bucket" {
  description = "S3 bucket every other stack stores its state in."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "ARN of the Terraform state bucket."
  value       = aws_s3_bucket.state.arn
}

output "state_region" {
  description = "Region of the Terraform state bucket."
  value       = var.aws_region
}

output "state_kms_key_arn" {
  description = "KMS key encrypting the state bucket."
  value       = aws_kms_key.state.arn
}

output "github_oidc_provider_arn" {
  description = "The GitHub Actions OIDC provider, created or read according to manage_oidc_provider."
  value       = local.oidc_provider_arn
}
