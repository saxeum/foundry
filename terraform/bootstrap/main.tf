data "aws_caller_identity" "current" {}

locals {
  # The account id makes the bucket globally unique without a hand-maintained
  # collision suffix. One bucket for the platform, not one per environment.
  state_bucket = "${var.project}-terraform-state-${data.aws_caller_identity.current.account_id}"

  # The provider is account-global and one per URL. Whether foundry creates it
  # or reads it is a variable because both cases are real: a fresh account has
  # none, and an account that previously ran another platform already has one.
  oidc_url = "https://${var.github_oidc_host}"
  oidc_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${var.github_oidc_host}"

  oidc_provider_arn = var.manage_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.manage_oidc_provider ? 1 : 0

  url            = local.oidc_url
  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = var.github_oidc_thumbprints
}

# The other half of the same choice: read the provider the account already has.
# This is the preflight when manage_oidc_provider is false; if the provider is
# missing, the plan stops here rather than creating a role that trusts nothing.
data "aws_iam_openid_connect_provider" "github" {
  count = var.manage_oidc_provider ? 0 : 1

  arn = local.oidc_arn
}

resource "aws_s3_bucket" "state" {
  bucket        = local.state_bucket
  force_destroy = false

  tags = {
    Name = local.state_bucket
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_kms_key" "state" {
  description         = "${var.project} Terraform state bucket"
  enable_key_rotation = true
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.project}-terraform-state"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "state" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket     = aws_s3_bucket.state.id
  policy     = data.aws_iam_policy_document.state.json
  depends_on = [aws_s3_bucket_public_access_block.state]
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
