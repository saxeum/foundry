output "cluster_name" {
  description = "EKS cluster name, for aws eks update-kubeconfig."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Private Kubernetes API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority" {
  description = "Cluster CA, base64. The kubeconfig carries it."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "IRSA provider. Workload roles trust it."
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "oidc_issuer" {
  description = "Cluster OIDC issuer URL."
  value       = local.oidc_issuer
}

output "node_security_group_id" {
  description = "Security group the nodes run in. RDS accepts 5432 from it."
  value       = local.node_security_group
}

output "bastion_instance_id" {
  description = "SSM bastion instance, the target of make eks-tunnel."
  value       = aws_instance.bastion.id
}
