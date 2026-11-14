# ============================================================================
# Bootstrap Module Outputs
# ============================================================================
# These outputs provide the resource identifiers and ARNs needed for:
# - Backend configuration in the main LiteLLM module
# - IAM policy attachment for deployment principals
# ============================================================================

# -----------------------------------------------------------------------------
# Terraform State Bucket Outputs
# -----------------------------------------------------------------------------

output "state_bucket_name" {
  description = "Name of the S3 bucket for Terraform state storage. Use this value in the main module's backend configuration."
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  description = "ARN of the S3 state bucket. Use this for IAM policy definitions that need to grant state access."
  value       = aws_s3_bucket.terraform_state.arn
}

# -----------------------------------------------------------------------------
# LiteLLM Configuration Bucket Outputs
# -----------------------------------------------------------------------------

output "config_bucket_name" {
  description = "Name of the S3 bucket for LiteLLM configuration files. Pass this to the main module's config_bucket_name variable."
  value       = aws_s3_bucket.litellm_config.id
}

output "config_bucket_arn" {
  description = "ARN of the S3 config bucket. Use this for IAM policy definitions that need to grant config access."
  value       = aws_s3_bucket.litellm_config.arn
}

# -----------------------------------------------------------------------------
# Deployment IAM Policy Outputs
# -----------------------------------------------------------------------------

output "deployment_policy_core_arn" {
  description = "ARN of the core infrastructure IAM policy. Attach this to deployment roles."
  value       = aws_iam_policy.deployment_core.arn
}

output "deployment_policy_networking_arn" {
  description = "ARN of the networking & security IAM policy. Attach this to deployment roles."
  value       = aws_iam_policy.deployment_networking.arn
}

output "deployment_policy_supporting_arn" {
  description = "ARN of the supporting services IAM policy. Attach this to deployment roles."
  value       = aws_iam_policy.deployment_supporting.arn
}

output "deployment_policy_arns" {
  description = "List of all deployment policy ARNs. Attach all three to CI/CD or developer roles."
  value = [
    aws_iam_policy.deployment_core.arn,
    aws_iam_policy.deployment_networking.arn,
    aws_iam_policy.deployment_supporting.arn
  ]
}
