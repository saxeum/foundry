data "aws_caller_identity" "current" {}

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = "${var.project}-terraform-state-${data.aws_caller_identity.current.account_id}"
    key    = "network/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "cluster" {
  backend = "s3"

  config = {
    bucket = "${var.project}-terraform-state-${data.aws_caller_identity.current.account_id}"
    key    = "cluster/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  oidc_issuer = data.terraform_remote_state.cluster.outputs.oidc_issuer
  oidc_host   = replace(local.oidc_issuer, "https://", "")
  lbc_sa      = "system:serviceaccount:kube-system:aws-load-balancer-controller"
}

# ---- AWS Load Balancer Controller ------------------------------------------
#
# The controller turns an Ingress into an ALB with pod IPs in the target groups.
# A hand-built aws_lb cannot do that: instance targets route through the node's
# kube-proxy and lose the pod's identity, which readiness and per-pod health
# checks both need.
#
# It lives in this stack because it needs the Helm provider, which needs the
# tunnel. The cluster stack stays pure AWS API and can be applied with the
# tunnel down.

data "aws_iam_policy_document" "lbc_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.terraform_remote_state.cluster.outputs.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = [local.lbc_sa]
    }
  }
}

resource "aws_iam_role" "lbc" {
  name               = "${var.project}-lbc"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume.json
}

# Vendored rather than referenced: the policy is what lets the controller create
# and delete load balancers, so it is reviewed like code.
resource "aws_iam_policy" "lbc" {
  name   = "${var.project}-lbc"
  policy = file("${path.module}/policies/aws-load-balancer-controller.json")
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "helm_release" "lbc" {
  name       = "aws-load-balancer-controller"
  chart      = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  version    = "3.7.0"
  namespace  = "kube-system"

  set = [
    { name = "clusterName", value = data.terraform_remote_state.cluster.outputs.cluster_name },
    { name = "region", value = var.aws_region },
    { name = "vpcId", value = data.terraform_remote_state.network.outputs.vpc_id },
    { name = "serviceAccount.create", value = "true" },
    { name = "serviceAccount.name", value = "aws-load-balancer-controller" },
    { name = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn", value = aws_iam_role.lbc.arn },
  ]

  wait    = true
  timeout = 300
}

# ---- The edge certificate --------------------------------------------------
#
# One wildcard for one label under the zone. A certificate per app would make
# every onboarding a DNS validation wait; the wildcard is issued once.
resource "aws_acm_certificate" "edge" {
  domain_name       = "*.${var.zone}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# The zone is in Cloudflare. The token comes from CLOUDFLARE_API_TOKEN and needs
# Zone:Read and Zone:DNS:Edit on this one zone — nothing account-wide.
data "cloudflare_zone" "edge" {
  filter = {
    name = var.zone
  }
}

# DNS only. ACM fetches this name itself and a proxied record would answer with
# Cloudflare's edge addresses instead of the value it is looking for.
resource "cloudflare_dns_record" "certificate_validation" {
  for_each = {
    for option in aws_acm_certificate.edge.domain_validation_options : option.domain_name => option
  }

  zone_id = data.cloudflare_zone.edge.zone_id
  name    = trimsuffix(each.value.resource_record_name, ".")
  type    = each.value.resource_record_type
  content = trimsuffix(each.value.resource_record_value, ".")
  ttl     = 300
  proxied = false
}

resource "aws_acm_certificate_validation" "edge" {
  certificate_arn = aws_acm_certificate.edge.arn

  validation_record_fqdns = [for record in cloudflare_dns_record.certificate_validation : record.name]
}

# Grey (DNS only), on purpose: clients reach the ALB and see its ACM certificate,
# so there is no second TLS hop to configure. The ALB does not exist until the
# first Ingress is synced, which is why this is empty on the first apply.
resource "cloudflare_dns_record" "app" {
  count = var.alb_hostname == "" ? 0 : 1

  zone_id = data.cloudflare_zone.edge.zone_id
  name    = var.app_hostname
  type    = "CNAME"
  content = var.alb_hostname
  ttl     = 300
  proxied = false
}

# ---- ALB access logs -------------------------------------------------------
#
# The ALB keeps no record of what hit it. Access logs are the input a rate limit
# or a WAF rule needs, and the only place to reconstruct an incident.
#
# SSE-S3, not a customer KMS key: ALB access logs do not support SSE-KMS with a
# CMK. This is the one bucket in the platform that is not on the KMS pattern,
# and the exception is deliberate.

resource "aws_s3_bucket" "alb_logs" {
  bucket = "${var.project}-alb-logs-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.project}-alb-logs"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ObjectWriter rather than BucketOwnerEnforced: the delivery service writes the
# object and asks for bucket-owner-full-control, which only does anything while
# ACLs are enabled. Public access stays blocked either way.
resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    object_ownership = "ObjectWriter"
  }
}

#trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid    = "ELBAccessLogs"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/foundry/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.alb_logs.arn, "${aws_s3_bucket.alb_logs.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket     = aws_s3_bucket.alb_logs.id
  policy     = data.aws_iam_policy_document.alb_logs.json
  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}

# ---- WAF -------------------------------------------------------------------
#
# Count mode until the logs say what would have been blocked. Every rule is
# present and evaluating; none blocks yet. A WAF switched straight into block
# mode on a working site is how a launch takes itself down at the first false
# positive, and the external tier is where it moves to block.

resource "aws_wafv2_web_acl" "edge" {
  name        = "${var.project}-edge"
  description = "Rules in front of the foundry ALB. Count mode until the logs say otherwise."
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "aws-common"
    priority = 1

    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-common"
      sampled_requests_enabled   = true
    }
  }

  # Scoped to /api/ because that is the only path that costs a database round
  # trip before it can be refused. 100 per address per five minutes is a floor
  # with a margin, not a measurement of a busy day.
  rule {
    name     = "api-rate"
    priority = 2

    action {
      count {}
    }

    statement {
      rate_based_statement {
        limit              = 100
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/"
            positional_constraint = "STARTS_WITH"

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-api-rate"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-edge"
    sampled_requests_enabled   = true
  }
}

# Metrics are not enough to run a WAF. CountedRequests says a rule matched; it
# does not say which one. The log is what makes count mode a decision rather
# than an assumption.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.project}-edge"
  retention_in_days = 30
}

data "aws_iam_policy_document" "waf_logs" {
  statement {
    sid    = "AllowWAFLogDelivery"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.waf.arn}:*"]
  }
}

resource "aws_cloudwatch_log_resource_policy" "waf_logs" {
  policy_name     = "${var.project}-waf-log-delivery"
  policy_document = data.aws_iam_policy_document.waf_logs.json
}

resource "aws_wafv2_web_acl_logging_configuration" "edge" {
  resource_arn            = aws_wafv2_web_acl.edge.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # The session cookie is a bearer token. Nothing in a decision about which rule
  # fired needs it, and a log group is readable by more people than the database.
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  depends_on = [aws_cloudwatch_log_resource_policy.waf_logs]
}
