data "aws_caller_identity" "current" {}

locals {
  apps     = toset(var.apps)
  registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"

  # The account-global provider bootstrap creates (or reads). One per URL per
  # account; the registry only reads it, the bootstrap owns its lifecycle.
  oidc_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_iam_openid_connect_provider" "github" {
  arn = local.oidc_arn
}

resource "aws_ecr_repository" "api" {
  for_each = local.apps

  name                 = "${each.key}-api"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${each.key}-api"
  }
}

resource "aws_ecr_repository" "web" {
  for_each = local.apps

  name                 = "${each.key}-web"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${each.key}-web"
  }
}

data "aws_ecr_lifecycle_policy_document" "default" {
  rule {
    priority    = 1
    description = "Expire untagged images after 7 days"

    selection {
      tag_status   = "untagged"
      count_type   = "sinceImagePushed"
      count_unit   = "days"
      count_number = 7
    }

    action {
      type = "expire"
    }
  }

  rule {
    priority    = 2
    description = "Keep the most recent 20 tagged images"

    selection {
      tag_status       = "tagged"
      tag_pattern_list = ["*"]
      count_type       = "imageCountMoreThan"
      count_number     = 20
    }

    action {
      type = "expire"
    }
  }
}

resource "aws_ecr_lifecycle_policy" "api" {
  for_each = local.apps

  repository = aws_ecr_repository.api[each.key].name
  policy     = data.aws_ecr_lifecycle_policy_document.default.json
}

resource "aws_ecr_lifecycle_policy" "web" {
  for_each = local.apps

  repository = aws_ecr_repository.web[each.key].name
  policy     = data.aws_ecr_lifecycle_policy_document.default.json
}

# One push role per app. The subject is the app's main branch, so a fork or a
# pull request cannot assume it; the permission is that app's repositories only.
data "aws_iam_policy_document" "push_assume" {
  for_each = local.apps

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      # GitHub's immutable subject appends the owner and repository ids. Accept
      # both it and the legacy name-only form; the branch stays exact.
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"

      values = [
        "repo:${var.github_owner}/${each.key}:ref:refs/heads/main",
        "repo:${var.github_owner}@${var.github_owner_id}/${each.key}@*:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "push" {
  for_each = local.apps

  name               = "${each.key}-github-push"
  assume_role_policy = data.aws_iam_policy_document.push_assume[each.key].json
}

data "aws_iam_policy_document" "push" {
  for_each = local.apps

  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushAndPullImages"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]

    resources = ["arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${each.key}-*"]
  }
}

resource "aws_iam_role_policy" "push" {
  for_each = local.apps

  name   = "${each.key}-github-push"
  role   = aws_iam_role.push[each.key].id
  policy = data.aws_iam_policy_document.push[each.key].json
}
