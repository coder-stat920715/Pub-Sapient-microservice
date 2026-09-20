locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

##############################################
# ALB SECURITY GROUP
# Internet-facing. Accepts 80/443 from the public internet only.
##############################################
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Controls access to the Application Load Balancer"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from internet (redirected to HTTPS at listener level)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow ALB to forward traffic to ECS tasks and health-check them"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-alb-sg"
  })
}

##############################################
# ECS TASK SECURITY GROUP
# NOT internet-facing. Only accepts traffic on the container port,
# and ONLY from the ALB security group (SG-to-SG reference, not a CIDR).
# This is the "security group chaining" pattern: the source of the
# ingress rule is another security group ID, so as ALB ENIs scale
# in/out the rule is always correct -- no IP management required.
##############################################
resource "aws_security_group" "ecs_task" {
  name        = "${local.name_prefix}-ecs-task-sg"
  description = "Allows inbound traffic to ECS tasks ONLY from the ALB security group"
  vpc_id      = var.vpc_id

  ingress {
    description     = "App traffic from ALB only"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow outbound to VPC endpoints (S3/Secrets Manager/ECR/Logs) and NAT for anything else"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-ecs-task-sg"
  })
}
