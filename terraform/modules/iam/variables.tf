variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "s3_bucket_arn" {
  description = "ARN of the specific S3 bucket the application is allowed to access (no wildcards across buckets)"
  type        = string
}

variable "secrets_manager_secret_arn" {
  description = "ARN of the specific Secrets Manager secret the application is allowed to read"
  type        = string
}

variable "log_group_arn" {
  description = "ARN of the CloudWatch Log Group this service is allowed to write to"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
