# ============================================================================
# Bootstrap Module Variables
# ============================================================================
# These variables are used to configure the foundational resources for
# Terraform state management and LiteLLM configuration storage.
# ============================================================================

# ----------------------------------------------------------------------------
# Required Variables
# ----------------------------------------------------------------------------

variable "tenant" {
  description = "Tenant identifier for resource naming. Used as a prefix for all resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.tenant)) && length(var.tenant) >= 2 && length(var.tenant) <= 32
    error_message = "Tenant must be 2-32 characters, lowercase alphanumeric with hyphens allowed (not at start/end)."
  }
}

variable "environment" {
  description = "Environment name for resource isolation (e.g., staging, production)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.environment)) && length(var.environment) >= 2 && length(var.environment) <= 16
    error_message = "Environment must be 2-16 characters, lowercase alphanumeric with hyphens allowed (not at start/end)."
  }
}

variable "aws_region" {
  description = "AWS region for deployment of all resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "AWS region must be a valid region identifier (e.g., us-east-1, eu-west-1)."
  }
}

# ----------------------------------------------------------------------------
# Optional Variables - Bucket Name Overrides
# ----------------------------------------------------------------------------

variable "state_bucket_name" {
  description = "Optional override for the S3 state bucket name. If not provided, defaults to '{tenant}-{environment}-litellm-state'."
  type        = string
  default     = null

  validation {
    condition     = var.state_bucket_name == null || (can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.state_bucket_name)) && length(var.state_bucket_name) >= 3 && length(var.state_bucket_name) <= 63)
    error_message = "State bucket name must be 3-63 characters, lowercase alphanumeric with hyphens and dots allowed (not at start/end)."
  }
}

variable "config_bucket_name" {
  description = "Optional override for the S3 config bucket name. If not provided, defaults to '{tenant}-{environment}-litellm-config'."
  type        = string
  default     = null

  validation {
    condition     = var.config_bucket_name == null || (can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.config_bucket_name)) && length(var.config_bucket_name) >= 3 && length(var.config_bucket_name) <= 63)
    error_message = "Config bucket name must be 3-63 characters, lowercase alphanumeric with hyphens and dots allowed (not at start/end)."
  }
}

# ----------------------------------------------------------------------------
# Optional Variables - Lifecycle Configuration
# ----------------------------------------------------------------------------

variable "noncurrent_version_expiration_days" {
  description = "Number of days to retain non-current versions in S3 buckets before expiration. Applies to both state and config buckets."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_expiration_days >= 1 && var.noncurrent_version_expiration_days <= 365
    error_message = "Noncurrent version expiration days must be between 1 and 365."
  }
}
