output "topic_arn" {
  description = "SNS topic Alertmanager and CloudWatch alarms publish to."
  value       = aws_sns_topic.alerts.arn
}

output "topic_name" {
  description = "SNS topic name."
  value       = aws_sns_topic.alerts.name
}

output "budget_name" {
  description = "Monthly cost budget."
  value       = aws_budgets_budget.monthly.name
}
