terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Recommended for production: remote state with locking.
  # backend "s3" {
  #   bucket         = "Spring-svc-tfstate"
  #   key            = "prod/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "Spring-svc-tf-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix   = "${var.project_name}-${var.environment}"
  account_id    = data.aws_caller_identity.current.account_id
  log_group_arn = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${local.name_prefix}"
  s3_bucket_arn = "arn:aws:s3:::${var.s3_bucket_name}"
  secret_arn    = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.secrets_manager_secret_name}-??????"
}

##############################################################################
# NETWORKING
##############################################################################
module "vpc" {
  source = "./modules/vpc"

  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
  tags               = var.tags
}

##############################################################################
# SECURITY GROUPS (ALB -> ECS chaining)
##############################################################################
module "security_groups" {
  source = "./modules/security-groups"

  project_name   = var.project_name
  environment    = var.environment
  vpc_id         = module.vpc.vpc_id
  container_port = var.container_port
  tags           = var.tags
}

##############################################################################
# IAM (least privilege: execution role vs task role)
##############################################################################
module "iam" {
  source = "./modules/iam"

  project_name               = var.project_name
  environment                = var.environment
  aws_region                 = var.aws_region
  account_id                 = local.account_id
  s3_bucket_arn              = local.s3_bucket_arn
  secrets_manager_secret_arn = local.secret_arn
  log_group_arn              = local.log_group_arn
  tags                       = var.tags
}

##############################################################################
# ECS FARGATE + ALB
##############################################################################
module "ecs" {
  source = "./modules/ecs"

  project_name    = var.project_name
  environment     = var.environment
  aws_region      = var.aws_region
  vpc_id          = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids

  alb_sg_id      = module.security_groups.alb_sg_id
  ecs_task_sg_id = module.security_groups.ecs_task_sg_id

  ecs_task_execution_role_arn = module.iam.ecs_task_execution_role_arn
  ecs_task_role_arn           = module.iam.ecs_task_role_arn

  container_image = var.container_image
  container_port  = var.container_port
  task_cpu        = var.task_cpu
  task_memory     = var.task_memory
  desired_count   = var.desired_count

  s3_bucket_name              = var.s3_bucket_name
  secrets_manager_secret_name = var.secrets_manager_secret_name

  tags = var.tags
}
