variable "project_name" {
  description = "Project name, used as a prefix for all resource names"
  type        = string
  default     = "Spring-svc"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "single_nat_gateway" {
  description = "Set true in dev to save cost (single NAT, no HA); false in prod for one NAT per AZ."
  type        = bool
  default     = false
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "container_image" {
  description = "Full ECR image URI including tag"
  type        = string
}

variable "task_cpu" {
  type    = number
  default = 512
}

variable "task_memory" {
  type    = number
  default = 1024
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "s3_bucket_name" {
  description = "Name of the pre-existing (or separately provisioned) S3 bucket the app may access"
  type        = string
}

variable "secrets_manager_secret_name" {
  description = "Name of the Secrets Manager secret the app may read (e.g. prod/Spring-svc/db-credentials)"
  type        = string
}

variable "tags" {
  type = map(string)
  default = {
    ManagedBy = "Terraform"
    Team      = "Platform-Engineering"
  }
}
