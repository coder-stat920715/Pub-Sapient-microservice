variable "project_name" {
  description = "Project name used for resource naming/tagging"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to span"
  type        = number
  default     = 2
}

variable "single_nat_gateway" {
  description = "If true, deploy one NAT Gateway (cost-optimized, single point of failure). If false, one NAT Gateway per AZ (HA, higher cost)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}
