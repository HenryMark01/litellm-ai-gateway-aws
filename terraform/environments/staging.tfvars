# ============================================================================
# Production Environment Configuration (Cost-Optimized for Small Teams)
# ============================================================================
# This file contains environment-specific configuration for LiteLLM on AWS.
# Optimized for cost efficiency while maintaining production-grade data safety.
#
# Estimated monthly cost: ~$70-100 (excluding LLM API usage)
#
# Usage:
#   terraform plan -var-file=../environments/prod.tfvars
#   terraform apply -var-file=../environments/prod.tfvars
#
# ============================================================================

# --------------------------------------------------------------------------
# Core Configuration (Required)
# --------------------------------------------------------------------------
# These values uniquely identify this deployment and determine resource naming.
# All resources will be named with the pattern: {tenant}-litellm-{environment}
# NOTE: Using "staging" naming to match existing bootstrap resources.
# This is functionally production - the name is just a label.

tenant      = "acme"    # Matches bootstrap resources
environment = "staging"   # Matches bootstrap S3 buckets (acme-staging-litellm-*)
aws_region  = "us-east-1" # AWS region for deployment

# Availability zones - minimum 2 required for Aurora and ALB
# Using 2 AZs satisfies AWS requirements while optimizing costs
availability_zones = ["us-east-1a", "us-east-1b"]

# --------------------------------------------------------------------------
# Networking Configuration
# --------------------------------------------------------------------------
# VPC configuration for production environment

vpc_cidr = "10.0.0.0/16" # VPC CIDR block

# --------------------------------------------------------------------------
# TLS/HTTPS Configuration
# --------------------------------------------------------------------------
# For production, HTTPS is recommended but optional for cost savings.
# You can start with HTTP and add TLS later when you have a domain.

# Option 1: HTTP-only mode (no TLS) - OK for internal/private use
allow_plaintext_alb = true
acm_certificate_arn = ""

# Option 2: Use existing ACM certificate (uncomment and set ARN)
# allow_plaintext_alb   = false
# acm_certificate_arn   = "arn:aws:acm:us-east-1:123456789012:certificate/your-cert-id"

# Option 3: Create new ACM certificate (requires domain_name and hosted_zone_id)
# create_acm_certificate = true

# --------------------------------------------------------------------------
# DNS and Domain Configuration (Optional)
# --------------------------------------------------------------------------
# Leave empty to use ALB DNS name directly (e.g., litellm-alb-123.us-east-1.elb.amazonaws.com)
# Add custom domain later when needed

domain_name    = "" # Optional: Custom domain (e.g., "api.example.com")
hosted_zone_id = "" # Optional: Route53 hosted zone ID

# --------------------------------------------------------------------------
# Container Images
# --------------------------------------------------------------------------
# Using stable images - pin to specific versions for predictability

litellm_gateway_image    = "ghcr.io/berriai/litellm-gateway:v1.106.3"
litellm_backend_image    = "ghcr.io/berriai/litellm-backend:v1.106.3"
litellm_ui_image         = "ghcr.io/berriai/litellm-ui:v1.106.3"
litellm_migrations_image = "ghcr.io/berriai/litellm-migrations:v1.106.3"

# --------------------------------------------------------------------------
# Gateway Service Configuration (Cost-Optimized)
# --------------------------------------------------------------------------
# Minimal but sufficient for small team production use

gateway_cpu    = 512  # 0.5 vCPU - sufficient for light workloads
gateway_memory = 2048 # 2 GB RAM - handles typical LLM proxy traffic

gateway_desired_count           = 1     # Start with 1 task, autoscaling adds more if needed
gateway_num_workers             = 1     # Single worker per task
gateway_connection_pool_enabled = false # Enable later if you see DB connection issues

# --------------------------------------------------------------------------
# Gateway Autoscaling Configuration
# --------------------------------------------------------------------------
# Conservative autoscaling - starts minimal, scales when needed

gateway_autoscaling_enabled = true
gateway_min_capacity        = 1  # Minimum 1 task (cost savings)
gateway_max_capacity        = 5  # Allow scaling up to 5 if traffic increases
gateway_cpu_target          = 70 # Scale out when CPU > 70%
gateway_memory_target       = 80 # Scale out when memory > 80%

# Disable request-based scaling (rely on CPU/memory)
gateway_target_requests_per_second = 0

# --------------------------------------------------------------------------
# Backend Service Configuration
# --------------------------------------------------------------------------
# Fixed count backend for predictable background processing

backend_cpu           = 512  # 0.5 vCPU
backend_memory        = 2048 # 2 GB RAM
backend_desired_count = 1    # Single task is sufficient for most workloads

backend_autoscaling_enabled = false # Fixed count

# --------------------------------------------------------------------------
# UI Service Configuration
# --------------------------------------------------------------------------
# Lightweight settings for admin dashboard

ui_cpu           = 256 # 0.25 vCPU
ui_memory        = 512 # 512 MB RAM
ui_desired_count = 1   # Single task

# --------------------------------------------------------------------------
# Database Configuration (Aurora PostgreSQL - Cost-Optimized)
# --------------------------------------------------------------------------
# db.t4g.medium: 2 vCPU, 4 GB RAM - good balance of cost and performance
# IMPORTANT: Data protection settings enabled for production

create_database    = true
db_instance_class  = "db.t4g.medium" # ~$50/month - sufficient for small teams
db_engine_version  = "16.8"
db_name            = "litellm"
db_master_username = "postgres"
db_username        = "litellm_app"

# PRODUCTION SETTING: Keep final snapshot on deletion to protect data
skip_final_snapshot = false

# --------------------------------------------------------------------------
# Cache Configuration (ElastiCache Redis - Cost-Optimized)
# --------------------------------------------------------------------------
# cache.t4g.micro: ~$9/month - smallest Graviton2 instance
# Single node is fine for small teams; add replicas later if needed

create_redis       = true
redis_node_type    = "cache.t4g.micro" # Smallest instance, ~$9/month
redis_num_replicas = 0                 # Single node (add replicas later for HA)

# --------------------------------------------------------------------------
# S3 Configuration
# --------------------------------------------------------------------------
# PRODUCTION SETTING: Protect S3 bucket from accidental deletion

s3_force_destroy = false

# --------------------------------------------------------------------------
# Secrets Configuration
# --------------------------------------------------------------------------
# PRODUCTION SETTING: 7-day recovery window protects against accidental deletion

secrets_recovery_window_days = 7 # Allows recovery of accidentally deleted secrets

# Leave empty to auto-generate secrets, or provide pre-existing values
litellm_master_key = ""
litellm_license    = "" # Leave empty for OSS deployment
ui_password        = "" # Falls back to master key if empty

# --------------------------------------------------------------------------
# Provider API Keys
# --------------------------------------------------------------------------
# Set these via environment variables or CI/CD secrets instead of tfvars:
#   export TF_VAR_openai_api_key="sk-..."
#   export TF_VAR_anthropic_api_key="sk-ant-..."
#
# Or override in command line:
#   terraform apply -var-file=prod.tfvars -var="openai_api_key=sk-..."

openai_api_key    = "" # Set via TF_VAR_openai_api_key
anthropic_api_key = "" # Set via TF_VAR_anthropic_api_key

# --------------------------------------------------------------------------
# Logging Configuration
# --------------------------------------------------------------------------
# 30 days retention - good balance of cost and troubleshooting capability

cloudwatch_log_retention_days = 30

# --------------------------------------------------------------------------
# Security Configuration
# --------------------------------------------------------------------------
# Open to internet - restrict to specific IPs if you have a fixed office IP

alb_allowed_cidr_blocks = ["0.0.0.0/0"]

# --------------------------------------------------------------------------
# Bastion Host (Optional - for database access)
# --------------------------------------------------------------------------
# Enable if you need direct database access for debugging

bastion_enabled                 = false
bastion_instance_type           = "t3.micro"
bastion_key_name                = "" # Set to your EC2 key pair name if enabling
bastion_allowed_rdp_cidr_blocks = [] # Add your admin IPs if enabling

# --------------------------------------------------------------------------
# CloudWatch Alarms
# --------------------------------------------------------------------------
# Production alarms with reasonable thresholds

enable_cloudwatch_alarms        = true
alarm_sns_topic_arn             = "" # Leave empty to create new topic
cpu_alarm_threshold             = 85 # Alert when CPU > 85%
memory_alarm_threshold          = 85 # Alert when memory > 85%
latency_alarm_threshold_seconds = 5  # Alert when requests take > 5s

# --------------------------------------------------------------------------
# Additional Tags
# --------------------------------------------------------------------------
# Tags applied to all resources for cost allocation and identification

additional_tags = {
  Environment = "staging" # Matches resource naming
  Project     = "litellm"
  ManagedBy   = "terraform"
}










# --------------------------------------------------------------------------
# Bedrock Cross-Account Access
# --------------------------------------------------------------------------
bedrock_cross_account_role_arns = [
  "arn:aws:iam::111122223333:role/BedrockCrossAccountAccessRole",
]

# --------------------------------------------------------------------------
# LiteLLM Config from S3 (Option 2 - Manual Upload Workflow)
# --------------------------------------------------------------------------
# Config file location: s3://acme-staging-litellm-config/config.yaml
# 
# Workflow to update config:
#   1. Edit configs/config.yaml locally
#   2. aws s3 cp configs/config.yaml s3://acme-staging-litellm-config/config.yaml --region us-east-1
#   3. aws ecs update-service --cluster acme-litellm-staging --service gateway --force-new-deployment --region us-east-1
#   4. aws ecs update-service --cluster acme-litellm-staging --service backend --force-new-deployment --region us-east-1
#
# To revert to Option 1 (Terraform-managed config), restore the proxy_config block
# and remove gateway_extra_env/backend_extra_env below.

gateway_extra_env = {
  LITELLM_CONFIG_BUCKET_NAME       = "acme-staging-litellm-config"
  LITELLM_CONFIG_BUCKET_OBJECT_KEY = "config.yaml"
  WORKER_CONFIG                    = "config.yaml"
}

backend_extra_env = {
  LITELLM_CONFIG_BUCKET_NAME       = "acme-staging-litellm-config"
  LITELLM_CONFIG_BUCKET_OBJECT_KEY = "config.yaml"
  WORKER_CONFIG                    = "config.yaml"
}

# S3 bucket for config (enables IAM policy for task role)
config_s3_bucket_name = "acme-staging-litellm-config"