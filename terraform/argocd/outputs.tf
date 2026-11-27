output "namespace" {
  description = "Namespace Argo CD is installed into."
  value       = var.namespace
}

output "chart_version" {
  description = "The installed argo-cd chart version."
  value       = var.chart_version
}
