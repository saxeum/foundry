data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  cluster_name = "${var.project}-staging"
  azs          = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.cluster_name
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = local.cluster_name
  }
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.cluster_name}-public-${count.index + 1}"
    Tier = "public"

    # How the AWS Load Balancer Controller finds subnets for an internet-facing
    # ALB. Without the role tag it reports "unable to discover subnets"; without
    # the cluster tag it ignores the subnet entirely.
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.cluster_name}-private-${count.index + 1}"
    Tier = "private"

    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.cluster_name}-public"
  }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.cluster_name}-private"
  }
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# One NAT gateway, in public-1, for ECR pulls, STS, EC2 and the EKS API. The
# single-AZ trade is deliberate and documented: if public-1 fails, running pods
# keep running and RDS is untouched, but nothing new can pull an image or reach
# the API. A NAT per AZ is the fix when that is no longer acceptable.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.cluster_name}-nat"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${local.cluster_name}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

# The node security group lives here because both the data stack (RDS ingress)
# and the cluster stack (node group, control plane rules) need it. Ingress rules
# are added by the cluster stack, where the cluster security group exists.
resource "aws_security_group" "eks_nodes" {
  name        = "${local.cluster_name}-nodes"
  description = "EKS worker nodes; RDS accepts 5432 from this group"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "VPC traffic: RDS, CoreDNS and the cluster endpoint ENIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "ECR, STS, EC2 and the EKS API, through the NAT gateway"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    #trivy:ignore:AVD-AWS-0104
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.cluster_name}-nodes"
  }
}

# No inbound rules and no SSH. The bastion is reached through SSM Session
# Manager only; its one job is a port forward to RDS and the private EKS API.
resource "aws_security_group" "bastion" {
  name        = "${local.cluster_name}-ssm-bastion"
  description = "SSM-only bastion; no inbound rules"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "SSM control plane"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    #trivy:ignore:AVD-AWS-0104
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Postgres in the VPC for port forwarding"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${local.cluster_name}-ssm-bastion"
  }
}

# VPC flow logs. Without them an incident has no record of which address talked
# to what, and the WAF's view stops at the ALB.
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/aws/vpc/${local.cluster_name}"
  retention_in_days = 30
}

data "aws_iam_policy_document" "flow_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow" {
  name               = "${local.cluster_name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_assume.json
}

data "aws_iam_policy_document" "flow" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]

    resources = ["${aws_cloudwatch_log_group.flow.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow" {
  name   = "${local.cluster_name}-vpc-flow-logs"
  role   = aws_iam_role.flow.id
  policy = data.aws_iam_policy_document.flow.json
}

resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow.arn
  log_destination = aws_cloudwatch_log_group.flow.arn
}
