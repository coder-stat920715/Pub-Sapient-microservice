locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

##############################################################################
# TRUST POLICY (shared) - only the ECS Tasks service can assume these roles
##############################################################################
data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

##############################################################################
# 1) ECS TASK EXECUTION ROLE
# Used by the ECS AGENT (not application code) before the container starts,
# to: pull the image from ECR and push container stdout/stderr to CloudWatch.
# Scope: this specific ECR repository + this specific log group. No S3, no
# Secrets Manager, no application data access whatsoever.
##############################################################################
resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "${local.name_prefix}-ecs-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
  tags               = merge(var.tags, { Name = "${local.name_prefix}-ecs-task-execution-role" })
}

data "aws_iam_policy_document" "ecs_task_execution_policy" {
  # ECR authorization token retrieval is account-wide by AWS API design;
  # this single action has no resource-level permissions, so "*" here is
  # the documented AWS requirement, not a shortcut around least privilege.
  statement {
    sid       = "ECRAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRImagePull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [
      "arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/${var.project_name}-${var.environment}"
    ]
  }

  statement {
    sid    = "CloudWatchLogsStreaming"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "${var.log_group_arn}:*"
    ]
  }
}

resource "aws_iam_policy" "ecs_task_execution_policy" {
  name        = "${local.name_prefix}-ecs-task-execution-policy"
  description = "Least-privilege policy: ECR image pull + CloudWatch log streaming only"
  policy      = data.aws_iam_policy_document.ecs_task_execution_policy.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_attach" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.ecs_task_execution_policy.arn
}

##############################################################################
# 2) ECS TASK ROLE
# Assumed by the APPLICATION CODE at runtime via the AWS SDK (credentials
# delivered through the ECS container credentials endpoint / IMDS-like
# mechanism). Scoped to exactly one S3 bucket and one Secrets Manager ARN --
# no wildcards, no cross-bucket or cross-secret access.
##############################################################################
resource "aws_iam_role" "ecs_task_role" {
  name               = "${local.name_prefix}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
  tags               = merge(var.tags, { Name = "${local.name_prefix}-ecs-task-role" })
}

data "aws_iam_policy_document" "ecs_task_role_policy" {
  statement {
    sid    = "S3ReadWriteSpecificBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      var.s3_bucket_arn,
      "${var.s3_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "SecretsManagerReadSpecificSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      var.secrets_manager_secret_arn
    ]
  }

  # Explicit deny as defense-in-depth: even if this policy is ever merged
  # with a broader one, deleting secrets is never permitted from the task role.
  statement {
    sid    = "DenySecretMutation"
    effect = "Deny"
    actions = [
      "secretsmanager:DeleteSecret",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecret",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ecs_task_role_policy" {
  name        = "${local.name_prefix}-ecs-task-role-policy"
  description = "Least-privilege application runtime policy: single S3 bucket + single secret ARN"
  policy      = data.aws_iam_policy_document.ecs_task_role_policy.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_role_attach" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.ecs_task_role_policy.arn
}
