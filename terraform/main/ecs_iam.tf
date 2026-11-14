# ============================================================================
# ECS IAM Extensions for LiteLLM
# ============================================================================
# This file adds additional IAM policies to the ECS task role created by the
# BerriAI/litellm/aws module. The module creates:
#
# - Task Execution Role: For ECS agent to pull images and retrieve secrets
# - Task Role: For running containers to access AWS services
#
# This file extends the Task Role with additional permissions not included
# in the base module.
#
# ============================================================================

# ============================================================================
# BEDROCK ACCESS POLICY
# ============================================================================
# When Bedrock is configured as a provider, THE ECS_Fargate task role SHALL
# have permissions to invoke Bedrock models.
#
# This policy grants the Gateway and Backend services permission to:
# - Invoke Bedrock models (bedrock:InvokeModel)
# - Invoke Bedrock models with streaming (bedrock:InvokeModelWithResponseStream)
# - List available models (bedrock:ListFoundationModels)
#
# Access is controlled by:
# 1. IAM policy (this file) - defines what the task CAN do
# 2. Bedrock model access policies - define which models are available
# 3. LiteLLM proxy_config - defines which models are exposed to clients
#
# For cross-account Bedrock access (e.g., models in a different AWS account),
# configure aws_role_name in proxy_config to assume a role in the target
# account that has bedrock:InvokeModel permissions.
# ============================================================================

# Variable to control Bedrock access (optional - can be disabled if not needed)
variable "enable_bedrock_access" {
  description = <<-EOT
    Enable AWS Bedrock access for ECS tasks.
    
    When true (default), the task role is granted permissions to invoke
    Bedrock models. This is required for:
    - Using Bedrock models directly (bedrock/*)
    - Using Claude models via Bedrock
    - Cross-account Bedrock access with IAM role assumption
    
    Set to false if you are not using any Bedrock models and want to
    follow the principle of least privilege.
  EOT
  type        = bool
  default     = true
}

# Data source to get the task role created by the module
# The module uses naming convention: {tenant}-litellm-{env}-task
data "aws_iam_role" "task" {
  name = "${var.tenant}-litellm-${var.environment}-task"

  depends_on = [module.litellm]
}

# IAM policy document for Bedrock access
data "aws_iam_policy_document" "bedrock_access" {
  count = var.enable_bedrock_access ? 1 : 0

  # Allow invoking Bedrock foundation models
  statement {
    sid    = "BedrockInvokeModel"
    effect = "Allow"

    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]

    # Allow access to all Bedrock models in the account
    # Model-level restrictions should be managed via Bedrock model access policies
    resources = [
      "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*",
      "arn:aws:bedrock:*::foundation-model/*",
    ]
  }

  # Allow listing available models (useful for /v1/models endpoint)
  statement {
    sid    = "BedrockListModels"
    effect = "Allow"

    actions = [
      "bedrock:ListFoundationModels",
      "bedrock:GetFoundationModel",
      "bedrock:ListInferenceProfiles",
      "bedrock:GetInferenceProfile",
    ]

    resources = ["*"]
  }

  # Allow assuming roles for cross-account Bedrock access
  # This enables the aws_role_name configuration in proxy_config
  # The target role must have a trust policy that allows this role to assume it
  dynamic "statement" {
    for_each = var.bedrock_cross_account_role_arns

    content {
      sid    = "BedrockCrossAccountAssumeRole${statement.key}"
      effect = "Allow"

      actions = ["sts:AssumeRole"]

      resources = [statement.value]
    }
  }
}

# Variable for cross-account Bedrock access
variable "bedrock_cross_account_role_arns" {
  description = <<-EOT
    List of IAM role ARNs that the ECS task role can assume for cross-account
    Bedrock access. Each role in the target account must:
    
    1. Have a trust policy allowing this role to assume it:
       {
         "Effect": "Allow",
         "Principal": {
           "AWS": "arn:aws:iam::THIS_ACCOUNT:role/{tenant}-litellm-{env}-task"
         },
         "Action": "sts:AssumeRole"
       }
    
    2. Have bedrock:InvokeModel permissions in that account
    
    Then configure aws_role_name in proxy_config:
      model_list:
        - model_name: "bedrock-cross-account/*"
          litellm_params:
            model: "bedrock/*"
            aws_role_name: "arn:aws:iam::TARGET_ACCOUNT:role/BedrockAccessRole"
    
    Example:
      bedrock_cross_account_role_arns = [
        "arn:aws:iam::111122223333:role/BedrockAccessRole",
        "arn:aws:iam::444455556666:role/BedrockAccessRole",
      ]
  EOT
  type        = list(string)
  default     = []
}

# IAM policy for Bedrock access
resource "aws_iam_policy" "bedrock_access" {
  count = var.enable_bedrock_access ? 1 : 0

  name        = "${var.tenant}-litellm-${var.environment}-bedrock-access"
  description = "Allows LiteLLM ECS tasks to invoke Bedrock models"
  policy      = data.aws_iam_policy_document.bedrock_access[0].json

  tags = merge(var.additional_tags, {
    "litellm:stack" = "${var.tenant}-litellm-${var.environment}"
    "managed-by"    = "terraform"
  })
}

# Attach Bedrock policy to the task role
resource "aws_iam_role_policy_attachment" "task_bedrock_access" {
  count = var.enable_bedrock_access ? 1 : 0

  role       = data.aws_iam_role.task.name
  policy_arn = aws_iam_policy.bedrock_access[0].arn
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "task_role_arn" {
  description = "ARN of the ECS task role used by Gateway and Backend services."
  value       = data.aws_iam_role.task.arn
}

output "task_role_name" {
  description = "Name of the ECS task role used by Gateway and Backend services."
  value       = data.aws_iam_role.task.name
}

output "bedrock_policy_arn" {
  description = "ARN of the Bedrock access IAM policy. Null when Bedrock access is disabled."
  value       = var.enable_bedrock_access ? aws_iam_policy.bedrock_access[0].arn : null
}


# ============================================================================
# S3 CONFIG BUCKET ACCESS (Option 2 - Manual Upload Workflow)
# ============================================================================
# Grants the ECS task role permission to read config.yaml from the bootstrap
# S3 bucket (acme-staging-litellm-config). This enables the native LiteLLM
# S3 config loading via LITELLM_CONFIG_BUCKET_NAME environment variable.
# ============================================================================

variable "config_s3_bucket_name" {
  description = <<-EOT
    Name of the S3 bucket containing LiteLLM config.yaml for Option 2 workflow.
    
    When set, the task role is granted read access to this bucket, enabling
    LiteLLM's native S3 config loading via LITELLM_CONFIG_BUCKET_NAME.
    
    Leave empty to use Option 1 (Terraform-managed proxy_config).
  EOT
  type        = string
  default     = ""
}

# IAM policy document for S3 config bucket access
data "aws_iam_policy_document" "config_s3_access" {
  count = var.config_s3_bucket_name != "" ? 1 : 0

  statement {
    sid    = "ConfigS3BucketAccess"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]

    resources = [
      "arn:aws:s3:::${var.config_s3_bucket_name}/*",
    ]
  }

  statement {
    sid    = "ConfigS3BucketList"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]

    resources = [
      "arn:aws:s3:::${var.config_s3_bucket_name}",
    ]
  }
}

# IAM policy for S3 config bucket access
resource "aws_iam_policy" "config_s3_access" {
  count = var.config_s3_bucket_name != "" ? 1 : 0

  name        = "${var.tenant}-litellm-${var.environment}-config-s3-access"
  description = "Allows LiteLLM ECS tasks to read config from S3 bucket"
  policy      = data.aws_iam_policy_document.config_s3_access[0].json

  tags = merge(var.additional_tags, {
    "litellm:stack" = "${var.tenant}-litellm-${var.environment}"
    "managed-by"    = "terraform"
  })
}

# Attach S3 config policy to the task role
resource "aws_iam_role_policy_attachment" "task_config_s3_access" {
  count = var.config_s3_bucket_name != "" ? 1 : 0

  role       = data.aws_iam_role.task.name
  policy_arn = aws_iam_policy.config_s3_access[0].arn
}

output "config_s3_policy_arn" {
  description = "ARN of the S3 config bucket access IAM policy. Null when not configured."
  value       = var.config_s3_bucket_name != "" ? aws_iam_policy.config_s3_access[0].arn : null
}
