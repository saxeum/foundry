data "aws_caller_identity" "current" {}

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = "${var.project}-terraform-state-${data.aws_caller_identity.current.account_id}"
    key    = "network/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  environments    = toset(var.environments)
  private_subnets = data.terraform_remote_state.network.outputs.private_subnet_ids
  node_sg         = data.terraform_remote_state.network.outputs.node_security_group_id
  bastion_sg      = data.terraform_remote_state.network.outputs.bastion_security_group_id
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db"
  subnet_ids = local.private_subnets

  tags = {
    Name = "${var.project}-db"
  }
}

resource "aws_db_parameter_group" "postgres" {
  name   = "${var.project}-postgres17"
  family = "postgres17"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  tags = {
    Name = "${var.project}-postgres17"
  }
}

# Postgres is reachable from the nodes and the SSM bastion, and from nowhere
# else. The node group is the same security group RDS already trusts, so an app
# pod reaches the database without a second rule.
resource "aws_security_group" "rds" {
  name        = "${var.project}-rds"
  description = "Postgres; only the EKS node and bastion security groups may connect"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  ingress {
    description     = "Postgres from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [local.node_sg]
  }

  ingress {
    description     = "Postgres from the SSM bastion"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [local.bastion_sg]
  }

  tags = {
    Name = "${var.project}-rds"
  }
}

# RDS owns the master password in Secrets Manager. Terraform never receives it,
# so it is not in state or a plan file.
#
# db_name is `foundry`, not the app's name: per-app databases are created by
# scripts/onboard-app.sh, so the instance has no application identity baked into
# it and adding an app does not touch this stack.
resource "aws_db_instance" "postgres" {
  for_each = local.environments

  identifier = "${var.project}-${each.key}"

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = "foundry"
  username = "foundry"

  manage_master_user_password = true

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name
  publicly_accessible    = false
  multi_az               = false

  ca_cert_identifier = var.db_ca_cert_identifier

  backup_retention_period = 7
  # Not immediate: a minor upgrade or parameter change lands in the maintenance
  # window rather than during a deployment.
  apply_immediately          = false
  auto_minor_version_upgrade = true

  # A destroy is a two-step by design. The seven-day point-in-time window is the
  # recovery path; a final snapshot is the belt to that braces for staging.
  deletion_protection       = true
  skip_final_snapshot       = each.key == "dev"
  final_snapshot_identifier = each.key == "dev" ? null : "${var.project}-${each.key}-final"
  copy_tags_to_snapshot     = true

  performance_insights_enabled    = true
  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = {
    Name        = "${var.project}-${each.key}"
    Environment = each.key
  }
}
