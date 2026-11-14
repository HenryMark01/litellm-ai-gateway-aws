# Terraform and Provider Version Constraints for Bootstrap Module
# This module creates foundational resources for state management and configuration storage

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
      Project-Name = "LiteLLM"
      Tenant       = var.tenant
      Environment  = var.environment
      ManagedBy    = "terraform"
      Module       = "bootstrap"
    }
  }
}
