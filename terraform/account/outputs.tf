output "detector_id" {
  description = "The GuardDuty detector."
  value       = aws_guardduty_detector.this.id
}

output "trail_name" {
  description = "The multi-region management-events trail."
  value       = aws_cloudtrail.management.name
}

output "trail_bucket" {
  description = "Bucket the trail writes to."
  value       = aws_s3_bucket.cloudtrail.id
}
