output "registry" {
  description = "ECR registry the app CI logs in to."
  value       = local.registry
}

output "image_repositories" {
  description = "Repository URLs, keyed by app and component."
  value = merge(
    { for app in local.apps : "${app}-api" => "${local.registry}/${app}-api" },
    { for app in local.apps : "${app}-web" => "${local.registry}/${app}-web" },
  )
}

output "push_role_arns" {
  description = "OIDC push role per app, set on the app repo as AWS_PUSH_ROLE_ARN."
  value       = { for app, role in aws_iam_role.push : app => role.arn }
}
