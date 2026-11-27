output "vpc_id" {
  description = "The foundry VPC."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "The foundry VPC CIDR."
  value       = aws_vpc.main.cidr_block
}

output "cluster_name" {
  description = "The cluster name the subnet tags are keyed on."
  value       = local.cluster_name
}

output "public_subnet_ids" {
  description = "Public subnets, for the ALB and the bastion."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnets, for EKS nodes and RDS."
  value       = aws_subnet.private[*].id
}

output "node_security_group_id" {
  description = "The EKS node security group. RDS accepts 5432 from it."
  value       = aws_security_group.eks_nodes.id
}

output "bastion_security_group_id" {
  description = "The SSM bastion security group."
  value       = aws_security_group.bastion.id
}

output "nat_public_ip" {
  description = "The single NAT gateway's address."
  value       = aws_eip.nat.public_ip
}
