output "db_identifiers" {
  description = "RDS instance identifiers, keyed by environment."
  value       = { for env, db in aws_db_instance.postgres : env => db.identifier }
}

output "db_endpoints" {
  description = "RDS hostnames, keyed by environment. `cut -d: -f1` is not needed; these are addresses."
  value       = { for env, db in aws_db_instance.postgres : env => db.address }
}

output "master_user_secret_arns" {
  description = "Secrets Manager ARNs holding the RDS-managed master credentials, per environment."
  value       = { for env, db in aws_db_instance.postgres : env => db.master_user_secret[0].secret_arn }
}

output "security_group_id" {
  description = "The RDS security group. Onboarding scripts use the tunnel, not this directly."
  value       = aws_security_group.rds.id
}
