variable "aws_region" {
  description = "AWS region for the databases."
  type        = string
  default     = "ap-southeast-2"
}

variable "project" {
  description = "Platform prefix for names and tags."
  type        = string
  default     = "foundry"
}

variable "environments" {
  description = "Environments with a database. One instance per environment, one database per app inside it."
  type        = list(string)
  default     = ["dev", "staging"]
}

variable "db_instance_class" {
  description = "RDS instance class. The smallest Graviton size while there is no customer load."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_engine_version" {
  description = "RDS Postgres engine version."
  type        = string
  default     = "17.12"
}

variable "db_ca_cert_identifier" {
  description = "RDS CA identifier used by verify-full clients."
  type        = string
  default     = "rds-ca-rsa4096-g1"
}
