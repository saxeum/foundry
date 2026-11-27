output "certificate_arn" {
  description = "Regional wildcard certificate for the ALB listener."
  value       = aws_acm_certificate.edge.arn
}

output "certificate_validation_records" {
  description = "Validation CNAMEs Terraform created in Cloudflare."
  value       = { for name, record in cloudflare_dns_record.certificate_validation : name => record.name }
}

output "waf_acl_arn" {
  description = "WAF ACL the Ingress annotation points at."
  value       = aws_wafv2_web_acl.edge.arn
}

output "alb_logs_bucket" {
  description = "Bucket the Ingress access_logs annotation points at."
  value       = aws_s3_bucket.alb_logs.bucket
}

output "lbc_role_arn" {
  description = "IRSA role the controller uses; the ALB it creates is owned by the Ingress."
  value       = aws_iam_role.lbc.arn
}

output "app_hostname_record" {
  description = "Where the app hostname points once alb_hostname is set."
  value       = var.alb_hostname == "" ? "(not set yet: apply the first Ingress, then pass its hostname as alb_hostname)" : "CNAME ${var.app_hostname} -> ${var.alb_hostname} (grey)"
}
