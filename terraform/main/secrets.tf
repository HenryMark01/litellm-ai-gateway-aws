# ============================================================================
# Secrets Management for LiteLLM
# ============================================================================
# This file manages secrets for the LiteLLM deployment:
#
# PART 1: MODULE-MANAGED SECRETS (Documentation Only)
#   - Master_Key, Salt_Key, Database Master Password
#   - These are created automatically by the BerriAI/litellm/aws module
#
# PART 2: PROVIDER API KEY SECRETS (Defined in this file)
#   - OpenAI API key, Anthropic API key, etc.
#   - These must be created separately and passed to the module
#
# ============================================================================

# ============================================================================
# PART 1: SECRETS MANAGED BY THE OFFICIAL BERRIAI MODULE
# ============================================================================
# The BerriAI/litellm/aws module (sourced in main.tf) automatically creates
# and manages the following secrets in AWS Secrets Manager:
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ 1. LITELLM_MASTER_KEY                                 │
# ├─────────────────────────────────────────────────────────────────────────┤
# │ Secret Name:  {tenant}-litellm-{env}-master-key                         │
# │ Description:  Primary authentication key for LiteLLM admin operations   │
# │ Generation:   Auto-generated with "sk-" prefix (48-char random string)  │
# │               OR user-provided via `litellm_master_key` variable        │
# │ Format:       sk-{48-char-random-alphanumeric}                          │
# │ Encryption:   AWS Secrets Manager default KMS key (aws/secretsmanager)  │
# │ Usage:        Gateway and Backend services via ECS secrets injection    │
# │                                                                         │
# │ To provide your own key, set var.litellm_master_key (must start with    │
# │ "sk-"). Leave empty for auto-generation.                                │
# └─────────────────────────────────────────────────────────────────────────┘
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ 2. DATABASE MASTER PASSWORD                           │
# ├─────────────────────────────────────────────────────────────────────────┤
# │ Secret Name:  {tenant}-litellm-{env}-db-master-password                 │
# │ Description:  Aurora PostgreSQL master password for bootstrap/admin     │
# │ Generation:   Auto-generated 32-char random password when               │
# │               create_database = true                                    │
# │ Format:       JSON with username, password, host, port, dbname          │
# │ Encryption:   AWS Secrets Manager default KMS key (aws/secretsmanager)  │
# │ Usage:        Emergency admin access via bastion host (break-glass)     │
# │                                                                         │
# │ IMPORTANT: ECS tasks use IAM database authentication, NOT this password.│
# │ The master password is only for:                                        │
# │   - Initial IAM user setup (granting rds_iam role)                      │
# │   - Emergency break-glass database access                               │
# │   - Schema migrations requiring superuser privileges                    │
# └─────────────────────────────────────────────────────────────────────────┘
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ 3. LITELLM_LICENSE (Optional)                                           │
# ├─────────────────────────────────────────────────────────────────────────┤
# │ Secret Name:  {tenant}-litellm-{env}-license                            │
# │ Description:  Enterprise license key for premium features               │
# │ Generation:   Only created when litellm_license variable is non-empty   │
# │ Encryption:   AWS Secrets Manager default KMS key                       │
# │ Usage:        Gateway and Backend services                              │
# └─────────────────────────────────────────────────────────────────────────┘
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ 4. UI_PASSWORD (Optional)                                               │
# ├─────────────────────────────────────────────────────────────────────────┤
# │ Secret Name:  {tenant}-litellm-{env}-ui-password                        │
# │ Description:  Admin UI login password                                   │
# │ Generation:   Only created when ui_password variable is non-empty       │
# │ Encryption:   AWS Secrets Manager default KMS key                       │
# │ Usage:        Backend service (falls back to master key if not set)     │
# └─────────────────────────────────────────────────────────────────────────┘
#
# ============================================================================
# SALT KEY CONSIDERATIONS
# ============================================================================
# The LiteLLM proxy uses a Salt_Key (LITELLM_SALT_KEY) for hashing operations.
# The official BerriAI module does NOT create a separate salt key secret.
#
# Current behavior:
#   - If LITELLM_SALT_KEY is not provided, LiteLLM derives one from the
#     master key automatically
#   - The module does not expose a variable for a custom salt key
#
# If a dedicated salt key is required for your deployment:
#   1. Create the secret manually in AWS Secrets Manager
#   2. Pass it via gateway_extra_secrets variable:
#        gateway_extra_secrets = {
#          LITELLM_SALT_KEY = "arn:aws:secretsmanager:region:account:secret:salt-key"
#        }
#
# ============================================================================
# KMS ENCRYPTION
# ============================================================================
# All secrets are encrypted by AWS Secrets Manager:
#
# Module-managed secrets:
#   - Use AWS managed key (aws/secretsmanager) by default
#   - This is automatic and requires no configuration
#
# Provider API key secrets (defined below):
#   - Also use AWS managed key by default
#   - Can be changed to customer-managed CMK if needed for compliance
#
# ============================================================================
# SECRET PATH MAPPING
# ============================================================================
# The requirements document specifies logical paths like:
#   /{tenant}/{environment}/litellm/master-key
#
# The module uses a hyphenated naming convention instead:
#   {tenant}-litellm-{environment}-master-key
#
# Mapping table:
# ┌────────────────────────────────────────┬────────────────────────────────────────┐
# │ Requirement Path                       │ Actual Secret Name                     │
# ├────────────────────────────────────────┼────────────────────────────────────────┤
# │ /{tenant}/{env}/litellm/master-key     │ {tenant}-litellm-{env}-master-key      │
# │ /{tenant}/{env}/litellm/salt-key       │ (derived from master key or custom)    │
# │ /{tenant}/{env}/litellm/db-password    │ {tenant}-litellm-{env}-db-master-password│
# └────────────────────────────────────────┴────────────────────────────────────────┘
#
# ============================================================================

# ============================================================================
# PART 2: PROVIDER API KEY SECRETS
# ============================================================================
# This section creates Secrets Manager secrets for LLM provider API keys and
# configures resource-based access policies for defense-in-depth security.
#
# IMPORTANT: The official BerriAI/litellm/aws module handles IAM permissions
# automatically. When you pass secret ARNs via `gateway_extra_secrets` or
# `backend_extra_secrets`, the module:
# 1. Adds the secret ARNs to the `secrets_access` IAM policy
# 2. Attaches that policy to the ECS task execution role
# 3. References the secrets in ECS task definitions
#
# The resource policies defined here provide an ADDITIONAL layer of security
# by ensuring only the ECS task execution role can access these secrets,
# even if another IAM principal has `secretsmanager:GetSecretValue` permission.
#
# ============================================================================

# --------------------------------------------------------------------------
# Data Sources for Resource Policies
# --------------------------------------------------------------------------
# The ECS task execution role is created by the BerriAI module with a
# predictable naming pattern: {tenant}-litellm-{env}-task-execution
#
# We construct the ARN directly rather than using a data source to avoid
# circular dependencies. The secrets need to be created before the module
# runs (so we can pass them via gateway_extra_secrets), but the resource
# policies need the task execution role to exist.
# --------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # Construct the task execution role ARN using the module's naming convention
  # This matches: aws_iam_role.task_execution in the BerriAI module's iam.tf
  task_execution_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.tenant}-litellm-${var.environment}-task-execution"
}

# --------------------------------------------------------------------------
# OpenAI API Key Secret
# --------------------------------------------------------------------------
# Stores the OpenAI API key for GPT-4, GPT-4o, and other OpenAI models.
# Referenced in config.yaml as: api_key: "os.environ/OPENAI_API_KEY"
# --------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "openai_api_key" {
  name        = "${var.tenant}-litellm-${var.environment}-openai-api-key"
  description = "OpenAI API key for LiteLLM proxy"

  # Use 0 for immediate deletion in non-production, or 7-30 for production
  recovery_window_in_days = var.secrets_recovery_window_days

  tags = merge(var.additional_tags, {
    "litellm:stack" = "${var.tenant}-litellm-${var.environment}"
    "managed-by"    = "terraform"
  })
}

resource "aws_secretsmanager_secret_version" "openai_api_key" {
  count = var.openai_api_key != "" ? 1 : 0

  secret_id     = aws_secretsmanager_secret.openai_api_key.id
  secret_string = var.openai_api_key
}

# --------------------------------------------------------------------------
# Anthropic API Key Secret
# --------------------------------------------------------------------------
# Stores the Anthropic API key for Claude models accessed directly
# (not via AWS Bedrock). Referenced as: api_key: "os.environ/ANTHROPIC_API_KEY"
# --------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "anthropic_api_key" {
  name        = "${var.tenant}-litellm-${var.environment}-anthropic-api-key"
  description = "Anthropic API key for LiteLLM proxy"

  recovery_window_in_days = var.secrets_recovery_window_days

  tags = merge(var.additional_tags, {
    "litellm:stack" = "${var.tenant}-litellm-${var.environment}"
    "managed-by"    = "terraform"
  })
}

resource "aws_secretsmanager_secret_version" "anthropic_api_key" {
  count = var.anthropic_api_key != "" ? 1 : 0

  secret_id     = aws_secretsmanager_secret.anthropic_api_key.id
  secret_string = var.anthropic_api_key
}

# ============================================================================
# Secret Resource Policies
# ============================================================================
# Resource policies on Secrets Manager secrets provide defense-in-depth by
# restricting access at the resource level. Even if an IAM principal has
# `secretsmanager:GetSecretValue` in their IAM policy, they cannot access
# these secrets unless the resource policy also allows it.
#
# Access is granted to:
# 1. ECS Task Execution Role - for injecting secrets into containers at startup
# 2. Account Root - for Terraform and admin management access
#
# IMPORTANT: Resource policies are applied AFTER the module creates the
# task execution role. The depends_on ensures proper ordering.
#
# The role ARN is constructed using the naming convention from the
# BerriAI/litellm module: {tenant}-litellm-{env}-task-execution
# ============================================================================

# --------------------------------------------------------------------------
# OpenAI API Key Resource Policy
# --------------------------------------------------------------------------

data "aws_iam_policy_document" "openai_api_key_policy" {
  # Allow ECS task execution role to read the secret
  statement {
    sid    = "AllowECSTaskExecutionRole"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [local.task_execution_role_arn]
    }

    actions = [
      "secretsmanager:GetSecretValue",
    ]

    resources = ["*"] # Resource policies use "*" to refer to the secret itself
  }

  # Allow the account root for Terraform management
  # This is necessary because resource policies can lock out management access
  statement {
    sid    = "AllowAccountManagement"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
    ]

    resources = ["*"]
  }
}

resource "aws_secretsmanager_secret_policy" "openai_api_key" {
  secret_arn = aws_secretsmanager_secret.openai_api_key.arn
  policy     = data.aws_iam_policy_document.openai_api_key_policy.json

  # Ensure the task execution role exists before applying the policy
  depends_on = [module.litellm]
}

# --------------------------------------------------------------------------
# Anthropic API Key Resource Policy
# --------------------------------------------------------------------------

data "aws_iam_policy_document" "anthropic_api_key_policy" {
  # Allow ECS task execution role to read the secret
  statement {
    sid    = "AllowECSTaskExecutionRole"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [local.task_execution_role_arn]
    }

    actions = [
      "secretsmanager:GetSecretValue",
    ]

    resources = ["*"]
  }

  # Allow the account root for Terraform management
  statement {
    sid    = "AllowAccountManagement"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
    ]

    resources = ["*"]
  }
}

resource "aws_secretsmanager_secret_policy" "anthropic_api_key" {
  secret_arn = aws_secretsmanager_secret.anthropic_api_key.arn
  policy     = data.aws_iam_policy_document.anthropic_api_key_policy.json

  # Ensure the task execution role exists before applying the policy
  depends_on = [module.litellm]
}

# ============================================================================
# Local Values for Module Integration
# ============================================================================
# These locals construct the maps needed for gateway_extra_secrets and
# backend_extra_secrets inputs to the BerriAI module.
#
# The secrets are ALWAYS created (even if no value is provided) so they
# exist for later population via the AWS CLI or console. The secret ARNs
# are ALWAYS passed to the module so the IAM permissions are configured
# upfront.
# ============================================================================

locals {
  # Provider API key secrets to pass to the module
  # Always include both secrets so IAM permissions are configured
  provider_secrets = {
    OPENAI_API_KEY    = aws_secretsmanager_secret.openai_api_key.arn
    ANTHROPIC_API_KEY = aws_secretsmanager_secret.anthropic_api_key.arn
  }
}
