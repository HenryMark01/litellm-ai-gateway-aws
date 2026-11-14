# Terraform and Provider Version Constraints for Main LiteLLM Module
# This module provisions LiteLLM infrastructure using the official BerriAI/litellm/aws module

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# AWS Provider Configuration
# Region is configured via variable to support multi-environment deployments
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "litellm"
      Tenant      = var.tenant
      Environment = var.environment
      ManagedBy   = "terraform"
      Module      = "main"
    }
  }
}
