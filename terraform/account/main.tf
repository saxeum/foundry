# Account-level detection.
#
# GuardDuty is the control that notices something happening rather than
# preventing it: a credential used from somewhere new, an instance mining, the
# EKS role assumed from a network this account does not use. The trail is the
# record that still exists after a resource is gone. Both are account-global,
# so they live in their own stack and are applied once per account.

data "aws_caller_identity" "current" {}

resource "aws_guardduty_detector" "this" {
  enable = true
}

# ---- CloudTrail ------------------------------------------------------------

# A customer-managed key, not SSE-S3. The archive is what answers "what happened
# in June"; a bucket protected only by its bucket policy is protected by the
# thing an attacker with the account changes first.
#
# A custom key policy replaces the default, so the account-root statement has to
# be written back or the key is not administrable by anyone.
data "aws_iam_policy_document" "cloudtrail_key" {
  statement {
    sid    = "AllowCloudTrailToEncrypt"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = [
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "AllowAccountAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }
}

resource "aws_kms_key" "cloudtrail" {
  description         = "${var.project} CloudTrail log encryption"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.cloudtrail_key.json
}

resource "aws_kms_alias" "cloudtrail" {
  name          = "alias/${var.project}-cloudtrail"
  target_key_id = aws_kms_key.cloudtrail.key_id
}

resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${var.project}-cloudtrail-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  tags = {
    Name = "${var.project}-cloudtrail"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning, because an audit object that can be overwritten in place is not
# evidence. A delivery that lands on the same key twice keeps both copies.
resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.cloudtrail.arn
    }
  }
}

# A year, not thirty days: the point of the bucket is the thing that answers
# "what happened in June". Noncurrent versions are the object-level history of a
# log that should never be rewritten; thirty days is enough to notice.
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

data "aws_iam_policy_document" "cloudtrail" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

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
    resources = [aws_s3_bucket.cloudtrail.arn, "${aws_s3_bucket.cloudtrail.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket     = aws_s3_bucket.cloudtrail.id
  policy     = data.aws_iam_policy_document.cloudtrail.json
  depends_on = [aws_s3_bucket_public_access_block.cloudtrail]
}

# One multi-region management-events trail. The name is foundry-specific on
# purpose: if an older trail with the generic name still exists, this one does
# not collide with it, and the runbook says which to keep.
resource "aws_cloudtrail" "management" {
  name                          = "${var.project}-management-events"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.cloudtrail.arn

  # The policy has to allow the write before the trail is pointed at the bucket,
  # or the first deliveries fail with the same silent error this trail exists to
  # prevent.
  depends_on = [aws_s3_bucket_policy.cloudtrail]
}
