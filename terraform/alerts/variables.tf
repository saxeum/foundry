variable "aws_region" {
  description = "AWS region for the topic and the budget."
  type        = string
  default     = "ap-southeast-2"
}

variable "project" {
  description = "Platform prefix for names and tags."
  type        = string
  default     = "foundry"
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget for the platform, in USD. The staging footprint is roughly $180; the budget is a ceiling, not a forecast."
  type        = number
  default     = 250
}

variable "alert_email" {
  description = "Address subscribed to the alerts topic. Empty creates the topic with no subscription, which is valid for a first apply and wrong for production."
  type        = string
  default     = ""
}

variable "alert_publisher_role_arns" {
  description = "IAM roles allowed to publish to the alerts topic, such as Alertmanager's IRSA role. Empty until P7 installs it."
  type        = list(string)
  default     = []
}
