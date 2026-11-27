data "aws_caller_identity" "current" {}

resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"

  tags = {
    Name = "${var.project}-alerts"
  }
}

# A custom topic policy replaces the default one, so the account's own
# administration statement is written back explicitly. Without it the topic is
# not administrable by anyone, which is the same trap the KMS policies document.
data "aws_iam_policy_document" "alerts" {
  statement {
    sid    = "AllowAccountAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["sns:*"]
    resources = [aws_sns_topic.alerts.arn]
  }

  # AWS Budgets publishes to the topic on its own behalf. Without this the budget
  # notification is created and never delivers, which is a silent failure.
  statement {
    sid    = "AllowBudgets"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  dynamic "statement" {
    for_each = var.alert_publisher_role_arns

    content {
      sid    = "AllowPublisher${statement.key}"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = [statement.value]
      }

      actions   = ["sns:Publish"]
      resources = [aws_sns_topic.alerts.arn]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Two notifications, because they answer different questions: "you have spent
# more than expected" (actual, 80%) and "at this rate you will" (forecasted,
# 100%). A budget with no notification is a dashboard nobody opens.
resource "aws_budgets_budget" "monthly" {
  name              = "${var.project}-monthly"
  budget_type       = "COST"
  limit_amount      = tostring(var.monthly_budget_usd)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-01_00:00"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }
}
