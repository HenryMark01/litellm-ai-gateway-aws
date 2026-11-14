# ============================================================================
# Terraform Backend Configuration for Remote State
# ============================================================================
# This file configures S3 as the remote backend for Terraform state storage.
# It uses the S3 bucket created by the bootstrap module.
#
# IMPORTANT: Backend configuration values must be static (cannot use variables).
# Update the values below to match your deployment:
#   - bucket: {tenant}-{environment}-litellm-state
#   - key: {tenant}/litellm/{environment}/terraform.tfstate
#   - region: your AWS region
#
# ============================================================================

terraform {
  backend "s3" {
    # S3 bucket for state storage (created by bootstrap module)
    # Pattern: {tenant}-{environment}-litellm-state
    bucket = "acme-staging-litellm-state"

    # State file key pattern for environment isolation
    # Pattern: {tenant}/litellm/{environment}/terraform.tfstate
    key = "acme/litellm/staging/terraform.tfstate"

    # AWS region where the state bucket is located
    region = "us-east-1"

    # Enable server-side encryption for state files at rest
    # This ensures sensitive data in state is encrypted in S3
    encrypt = true

    # Use Terraform 1.10+ native S3 locking instead of DynamoDB
    # This creates a .tflock file in S3 to prevent concurrent modifications
    # Requires Terraform >= 1.10
    use_lockfile = true
  }
}
