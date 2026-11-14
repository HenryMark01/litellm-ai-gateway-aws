# ============================================================================
# Bootstrap Module - S3 Buckets for State and Configuration Storage
# ============================================================================
# This module creates foundational S3 resources required before the main
# LiteLLM infrastructure deployment.
# ============================================================================

# ============================================================================
# S3 Bucket for Terraform State Storage
# ============================================================================
# Stores Terraform state files with versioning and encryption for secure
# collaborative infrastructure management.
# ============================================================================

resource "aws_s3_bucket" "terraform_state" {
  bucket = coalesce(var.state_bucket_name, "${var.tenant}-${var.environment}-litellm-state")

  tags = {
    Name    = coalesce(var.state_bucket_name, "${var.tenant}-${var.environment}-litellm-state")
    Purpose = "Terraform state storage"
  }

  # Prevent accidental deletion of state bucket
  lifecycle {
    prevent_destroy = true
  }
}

# Enable versioning for state rollback
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Enable server-side encryption with AES-256
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle rule to expire non-current versions after configured days
resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    # Apply to all objects in the bucket
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }

  # Ensure versioning is enabled before applying lifecycle rules
  depends_on = [aws_s3_bucket_versioning.terraform_state]
}

# ============================================================================
# S3 Bucket for LiteLLM Configuration Storage
# ============================================================================
# Stores config.yaml for LiteLLM proxy configuration
# ============================================================================

resource "aws_s3_bucket" "litellm_config" {
  bucket = "${var.tenant}-${var.environment}-litellm-config"

  tags = {
    Name    = "${var.tenant}-${var.environment}-litellm-config"
    Purpose = "LiteLLM configuration storage"
  }
}

# Enable versioning for configuration rollback
resource "aws_s3_bucket_versioning" "litellm_config" {
  bucket = aws_s3_bucket.litellm_config.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Enable server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "litellm_config" {
  bucket = aws_s3_bucket.litellm_config.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "litellm_config" {
  bucket = aws_s3_bucket.litellm_config.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ============================================================================
# IAM Policy Documents for Deployment Permissions (Split into 3 policies)
# ============================================================================
# AWS has a 6144 character limit for IAM policies. We split the permissions
# into multiple policies that can be attached to the same role/user.
# ============================================================================

# Get current AWS account ID and region for dynamic ARN construction
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Policy 1: Core Infrastructure (VPC, ECS, RDS, ElastiCache)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "deployment_core" {
  statement {
    sid    = "TerraformStateAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketVersioning",
      "s3:GetBucketLocation"
    ]
    resources = [
      "arn:aws:s3:::${var.tenant}-${var.environment}-litellm-state",
      "arn:aws:s3:::${var.tenant}-${var.environment}-litellm-state/*"
    ]
  }

  statement {
    sid    = "VPCManagement"
    effect = "Allow"
    actions = [
      "ec2:*Vpc*",
      "ec2:*Subnet*",
      "ec2:*InternetGateway*",
      "ec2:*NatGateway*",
      "ec2:*RouteTable*",
      "ec2:*Route",
      "ec2:*SecurityGroup*",
      "ec2:*Address*",
      "ec2:*NetworkAcl*",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:DescribeTags",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeAccountAttributes"
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ECSManagement"
    effect    = "Allow"
    actions   = ["ecs:*"]
    resources = ["*"]
  }

  statement {
    sid       = "RDSManagement"
    effect    = "Allow"
    actions   = ["rds:*"]
    resources = ["*"]
  }

  statement {
    sid       = "ElastiCacheManagement"
    effect    = "Allow"
    actions   = ["elasticache:*"]
    resources = ["*"]
  }
}

# ---------------------------------------------------------------------------
# Policy 2: Networking & Security (ALB, Secrets, IAM)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "deployment_networking" {
  statement {
    sid       = "LoadBalancerManagement"
    effect    = "Allow"
    actions   = ["elasticloadbalancing:*"]
    resources = ["*"]
  }

  statement {
    sid    = "SecretsManagerManagement"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:UpdateSecret",
      "secretsmanager:PutSecretValue",
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:PutResourcePolicy",
      "secretsmanager:DeleteResourcePolicy",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:ListSecrets",
      "secretsmanager:RestoreSecret"
    ]
    resources = [
      "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:/${var.tenant}/${var.environment}/litellm/*"
    ]
  }

  statement {
    sid    = "IAMManagement"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:GetRole",
      "iam:PassRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:*RolePolicy*",
      "iam:*AttachedRolePolicies*",
      "iam:*ServiceLinkedRole*",
      "iam:UpdateAssumeRolePolicy",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRoleTags",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:*PolicyVersion*",
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:ListPolicyTags"
    ]
    resources = ["*"]
  }
}

# ---------------------------------------------------------------------------
# Policy 3: Supporting Services (Route53, ACM, CloudWatch, KMS, S3, EC2)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "deployment_supporting" {
  statement {
    sid       = "Route53Management"
    effect    = "Allow"
    actions   = ["route53:*"]
    resources = ["*"]
  }

  statement {
    sid       = "ACMManagement"
    effect    = "Allow"
    actions   = ["acm:*"]
    resources = ["*"]
  }

  statement {
    sid       = "CloudWatchManagement"
    effect    = "Allow"
    actions   = ["logs:*", "cloudwatch:*"]
    resources = ["*"]
  }

  statement {
    sid       = "SNSManagement"
    effect    = "Allow"
    actions   = ["sns:*"]
    resources = ["*"]
  }

  statement {
    sid       = "ApplicationAutoScaling"
    effect    = "Allow"
    actions   = ["application-autoscaling:*"]
    resources = ["*"]
  }

  statement {
    sid       = "KMSManagement"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "S3ConfigBucketManagement"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:*Bucket*",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:*ObjectVersion*",
      "s3:*ObjectTagging*"
    ]
    resources = [
      "arn:aws:s3:::${var.tenant}-${var.environment}-litellm-*",
      "arn:aws:s3:::${var.tenant}-${var.environment}-litellm-*/*"
    ]
  }

  statement {
    sid    = "EC2InstanceManagement"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:*Instances",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeImages",
      "ec2:*KeyPair*",
      "ec2:ModifyInstanceAttribute",
      "ec2:*Volume*"
    ]
    resources = ["*"]
  }
}

# ============================================================================
# IAM Policy Resources (3 policies)
# ============================================================================

resource "aws_iam_policy" "deployment_core" {
  name        = "${var.tenant}-${var.environment}-litellm-deploy-core"
  description = "Core infrastructure permissions (VPC, ECS, RDS, ElastiCache)"
  policy      = data.aws_iam_policy_document.deployment_core.json

  tags = {
    Name    = "${var.tenant}-${var.environment}-litellm-deploy-core"
    Purpose = "Terraform deployment permissions - Core"
  }
}

resource "aws_iam_policy" "deployment_networking" {
  name        = "${var.tenant}-${var.environment}-litellm-deploy-network"
  description = "Networking & security permissions (ALB, Secrets, IAM)"
  policy      = data.aws_iam_policy_document.deployment_networking.json

  tags = {
    Name    = "${var.tenant}-${var.environment}-litellm-deploy-network"
    Purpose = "Terraform deployment permissions - Networking"
  }
}

resource "aws_iam_policy" "deployment_supporting" {
  name        = "${var.tenant}-${var.environment}-litellm-deploy-support"
  description = "Supporting services permissions (Route53, ACM, CloudWatch, KMS)"
  policy      = data.aws_iam_policy_document.deployment_supporting.json

  tags = {
    Name    = "${var.tenant}-${var.environment}-litellm-deploy-support"
    Purpose = "Terraform deployment permissions - Supporting"
  }
}

