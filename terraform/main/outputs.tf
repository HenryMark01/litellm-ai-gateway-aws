# ============================================================================
# Main LiteLLM Module Outputs
# ============================================================================
# These outputs expose key resource identifiers and endpoints for downstream
# consumption, operational management, and connectivity verification.
#
# ============================================================================

# ----------------------------------------------------------------------------
# Load Balancer Outputs
# ----------------------------------------------------------------------------

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer. Use this for direct access when not using a custom domain."
  value       = module.litellm.alb_dns_name
}

output "litellm_endpoint" {
  description = "Full HTTP(S) URL for the LiteLLM API endpoint. Use this for API client configuration."
  value       = module.litellm.alb_url
}

output "alb_endpoint_info" {
  description = "Summary of ALB endpoint configuration and access information."
  value       = <<-EOT
    LiteLLM Endpoint: ${local.dns_enabled ? "https://${var.domain_name}" : module.litellm.alb_url}
    
    Service Routing:
    - UI Dashboard:  ${local.dns_enabled ? "https://${var.domain_name}" : module.litellm.alb_url}/ui
    - API Gateway:   ${local.dns_enabled ? "https://${var.domain_name}" : module.litellm.alb_url}/v1/...
    - Health Check:  ${local.dns_enabled ? "https://${var.domain_name}" : module.litellm.alb_url}/health/readiness
    - Models List:   ${local.dns_enabled ? "https://${var.domain_name}" : module.litellm.alb_url}/v1/models
    
    TLS Status: ${local.effective_certificate_arn != "" ? "Enabled (HTTPS)" : "Disabled (HTTP only - not recommended for production)"}
    Custom Domain: ${local.dns_enabled ? var.domain_name : "Not configured (using ALB DNS)"}
    
    Example API Call:
    curl -X POST ${local.dns_enabled ? "https://${var.domain_name}" : module.litellm.alb_url}/v1/chat/completions \
      -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
      -H "Content-Type: application/json" \
      -d '{"model": "bedrock/us.anthropic.claude-sonnet-4-0-20250514-v1:0", "messages": [{"role": "user", "content": "Hello!"}]}'
  EOT
}

# ----------------------------------------------------------------------------
# DNS and Certificate Outputs
# ----------------------------------------------------------------------------
# Outputs for custom domain and ACM certificate configuration.
# ----------------------------------------------------------------------------

output "acm_certificate_arn" {
  description = <<-EOT
    ARN of the ACM certificate used for HTTPS on the ALB.
    
    This is either:
    - The certificate created by this configuration (when create_acm_certificate = true)
    - The certificate provided via acm_certificate_arn variable (when create_acm_certificate = false)
    - Empty string if no certificate is configured
  EOT
  value       = local.effective_certificate_arn
}

output "custom_domain_endpoint" {
  description = <<-EOT
    Custom domain URL for the LiteLLM endpoint.
    
    Returns the full HTTPS URL when a custom domain is configured, or null if using
    the ALB DNS name directly. Use this output for application configuration.
  EOT
  value       = local.dns_enabled ? "https://${var.domain_name}" : null
}

output "dns_configuration_status" {
  description = "Summary of DNS and certificate configuration for the deployment."
  value = {
    custom_domain_enabled = local.dns_enabled
    domain_name           = local.dns_enabled ? var.domain_name : null
    route53_managed       = local.route53_enabled
    certificate_created   = local.dns_enabled && var.create_acm_certificate
    certificate_arn       = local.effective_certificate_arn != "" ? local.effective_certificate_arn : null
    effective_endpoint    = local.dns_enabled ? "https://${var.domain_name}" : module.litellm.alb_url
  }
}

output "dns_manual_configuration" {
  description = <<-EOT
    Manual DNS configuration instructions when Route53 is not used.
    
    When hosted_zone_id is not provided but domain_name is set, these instructions
    explain how to configure DNS manually with your DNS provider.
  EOT
  value = local.dns_enabled && !local.route53_enabled ? {
    instructions = <<-INSTRUCTIONS
      Manual DNS Configuration Required
      ==================================
      
      Since no Route53 hosted zone ID was provided, you must configure DNS manually
      with your DNS provider.
      
      1. Create an A record or CNAME record:
         - Name: ${var.domain_name}
         - Type: CNAME (recommended) or A record
         - Value: ${module.litellm.alb_dns_name}
         - TTL: 300 (5 minutes) or lower
      
      ${var.create_acm_certificate ? "2. ACM Certificate Validation Records:\n         The following CNAME records must be created for certificate validation.\n         Check the 'acm_validation_records' output for the exact values required." : ""}
      
      After DNS is configured:
      - Wait for DNS propagation (5-30 minutes typically)
      - Verify with: dig ${var.domain_name}
      - Test endpoint: curl -I https://${var.domain_name}/health/readiness
    INSTRUCTIONS
    alb_dns_name = module.litellm.alb_dns_name
  } : null
}

output "acm_validation_records" {
  description = <<-EOT
    ACM certificate DNS validation records.
    
    When create_acm_certificate is true and hosted_zone_id is NOT provided,
    these CNAME records must be manually added to your DNS provider to validate
    the certificate. The certificate will not be issued until these records are
    accessible.
  EOT
  value = local.dns_enabled && var.create_acm_certificate && !local.route53_enabled ? {
    instructions = "Add the following CNAME records to your DNS provider for certificate validation:"
    records = [for dvo in aws_acm_certificate.litellm[0].domain_validation_options : {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
      note  = "Required for ACM certificate validation"
    }]
  } : null
}

# ----------------------------------------------------------------------------
# ECS Outputs
# ----------------------------------------------------------------------------

output "ecs_cluster_name" {
  description = "Name of the ECS Fargate cluster running LiteLLM services. Used for service management and monitoring."
  value       = module.litellm.ecs_cluster
}

output "gateway_service_name" {
  description = "Name of the Gateway ECS service. Used for force deployments and service updates."
  value       = "${var.tenant}-litellm-${var.environment}-gateway"
}

output "backend_service_name" {
  description = "Name of the Backend ECS service. Used for force deployments and service updates."
  value       = "${var.tenant}-litellm-${var.environment}-backend"
}

output "ui_service_name" {
  description = "Name of the UI ECS service. Used for force deployments and service updates."
  value       = "${var.tenant}-litellm-${var.environment}-ui"
}

# ----------------------------------------------------------------------------
# Database Outputs
# ----------------------------------------------------------------------------

output "database_endpoint" {
  description = "Aurora PostgreSQL cluster endpoint for connectivity verification and emergency admin access via bastion."
  value       = module.litellm.aurora_writer_endpoint
  sensitive   = true
}

output "database_reader_endpoint" {
  description = "Aurora PostgreSQL reader endpoint for read replicas."
  value       = module.litellm.aurora_reader_endpoint
  sensitive   = true
}

output "db_master_password_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the Aurora master password for admin access."
  value       = module.litellm.db_master_password_secret_arn
  sensitive   = true
}

output "db_bootstrap_sql" {
  description = "SQL commands to run as master user to create the IAM-authenticated application user."
  value       = module.litellm.db_bootstrap_sql
}

# ----------------------------------------------------------------------------
# Redis Cache Outputs
# ----------------------------------------------------------------------------

output "redis_endpoint" {
  description = "ElastiCache Redis endpoint for connectivity verification and cache monitoring."
  value       = module.litellm.redis_endpoint
  sensitive   = true
}

# ----------------------------------------------------------------------------
# S3 Outputs
# ----------------------------------------------------------------------------

output "s3_bucket" {
  description = "S3 bucket name for LiteLLM configuration and files."
  value       = module.litellm.s3_bucket
}

# ----------------------------------------------------------------------------
# Monitoring Outputs
# ----------------------------------------------------------------------------

output "cloudwatch_log_group" {
  description = "CloudWatch Log Group name for ECS container logs. Use for log access and debugging."
  value       = "/ecs/${var.tenant}-litellm-${var.environment}"
}

output "alarm_sns_topic_arn" {
  description = "ARN of the SNS topic used for CloudWatch alarm notifications. Null if alarms are disabled or using an external topic."
  value       = var.enable_cloudwatch_alarms && var.alarm_sns_topic_arn == "" ? aws_sns_topic.alarms[0].arn : var.alarm_sns_topic_arn
}

output "cloudwatch_alarms" {
  description = "Summary of CloudWatch alarms created for monitoring."
  value = var.enable_cloudwatch_alarms ? {
    enabled = true
    alarms = {
      gateway_cpu_high    = aws_cloudwatch_metric_alarm.gateway_cpu_high[0].alarm_name
      gateway_memory_high = aws_cloudwatch_metric_alarm.gateway_memory_high[0].alarm_name
      alb_5xx_error_rate  = aws_cloudwatch_metric_alarm.alb_5xx_error_rate[0].alarm_name
      alb_latency_high    = aws_cloudwatch_metric_alarm.alb_latency_high[0].alarm_name
    }
    thresholds = {
      cpu_percent     = var.cpu_alarm_threshold
      memory_percent  = var.memory_alarm_threshold
      error_rate      = "5%"
      latency_seconds = var.latency_alarm_threshold_seconds
    }
    sns_topic_arn = var.alarm_sns_topic_arn != "" ? var.alarm_sns_topic_arn : aws_sns_topic.alarms[0].arn
    } : {
    enabled       = false
    alarms        = {}
    thresholds    = {}
    sns_topic_arn = null
  }
}

# ----------------------------------------------------------------------------
# Autoscaling Outputs
# ----------------------------------------------------------------------------

output "autoscaling_configuration" {
  description = "Summary of autoscaling configuration for gateway and backend services."
  value = {
    gateway = {
      enabled                    = var.gateway_autoscaling_enabled
      min_tasks                  = var.gateway_min_capacity
      max_tasks                  = var.gateway_max_capacity
      cpu_target                 = var.gateway_cpu_target
      memory_target              = var.gateway_memory_target
      requests_per_second_target = var.gateway_target_requests_per_second
      scaling_behavior           = var.gateway_autoscaling_enabled ? "Scales based on CPU (${var.gateway_cpu_target}%), memory (${var.gateway_memory_target}%), and ALB requests" : "Fixed at ${var.gateway_desired_count} tasks"
    }
    backend = {
      enabled          = var.backend_autoscaling_enabled
      desired_count    = var.backend_desired_count
      scaling_behavior = var.backend_autoscaling_enabled ? "Scales based on CPU (${var.backend_cpu_target}%)" : "Fixed at ${var.backend_desired_count} task(s)"
    }
  }
}

# ----------------------------------------------------------------------------
# Secrets Outputs
# ----------------------------------------------------------------------------

output "master_key_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the LiteLLM master key."
  value       = module.litellm.master_key_secret_arn
  sensitive   = true
}

# ----------------------------------------------------------------------------
# Provider API Key Secret Outputs
# ----------------------------------------------------------------------------

output "openai_api_key_secret_arn" {
  description = "ARN of the Secrets Manager secret for the OpenAI API key. Update this secret with your actual API key after deployment."
  value       = aws_secretsmanager_secret.openai_api_key.arn
  sensitive   = true
}

output "openai_api_key_secret_name" {
  description = "Name of the Secrets Manager secret for the OpenAI API key."
  value       = aws_secretsmanager_secret.openai_api_key.name
}

output "anthropic_api_key_secret_arn" {
  description = "ARN of the Secrets Manager secret for the Anthropic API key. Update this secret with your actual API key after deployment."
  value       = aws_secretsmanager_secret.anthropic_api_key.arn
  sensitive   = true
}

output "anthropic_api_key_secret_name" {
  description = "Name of the Secrets Manager secret for the Anthropic API key."
  value       = aws_secretsmanager_secret.anthropic_api_key.name
}

# Note: Provider API key secrets use the AWS-managed KMS key (aws/secretsmanager)
# for encryption by default. This is automatic and requires no additional
# configuration. If you need customer-managed CMK for compliance, update
# the aws_secretsmanager_secret resources in secrets.tf with kms_key_id.

output "provider_api_key_update_commands" {
  description = "AWS CLI commands to update provider API key secrets after deployment."
  value       = <<-EOT
    # Update OpenAI API key:
    aws secretsmanager put-secret-value \
      --secret-id ${aws_secretsmanager_secret.openai_api_key.name} \
      --secret-string "sk-your-openai-api-key"

    # Update Anthropic API key:
    aws secretsmanager put-secret-value \
      --secret-id ${aws_secretsmanager_secret.anthropic_api_key.name} \
      --secret-string "sk-ant-your-anthropic-api-key"

    # After updating secrets, force a new deployment to pick up the changes:
    aws ecs update-service --cluster ${module.litellm.ecs_cluster} --service ${var.tenant}-litellm-${var.environment}-gateway --force-new-deployment
    aws ecs update-service --cluster ${module.litellm.ecs_cluster} --service ${var.tenant}-litellm-${var.environment}-backend --force-new-deployment
  EOT
}

# ----------------------------------------------------------------------------
# Network and Security Outputs
# ----------------------------------------------------------------------------

output "vpc_id" {
  description = "VPC ID where LiteLLM infrastructure is deployed."
  value       = module.litellm.vpc_id
}

output "task_security_group_id" {
  description = "Security group ID attached to ECS tasks. Use this to allow access from existing databases or caches."
  value       = module.litellm.task_security_group_id
}

# ----------------------------------------------------------------------------
# Migration Command
# ----------------------------------------------------------------------------

output "migration_run_command" {
  description = "AWS CLI command to run the database migration task. Execute this after initial deployment."
  value       = module.litellm.migration_run_command
}

# ----------------------------------------------------------------------------
# Windows Bastion Host Outputs (Conditional)
# ----------------------------------------------------------------------------

output "bastion_public_ip" {
  description = "Public IP address of the Windows bastion host for RDP access. Null when bastion is disabled."
  value       = var.bastion_enabled ? aws_eip.bastion[0].public_ip : null
}

output "bastion_instance_id" {
  description = "EC2 instance ID of the Windows bastion host. Use with 'aws ec2 get-password-data' to retrieve Administrator password."
  value       = var.bastion_enabled ? aws_instance.bastion[0].id : null
}

output "bastion_rdp_command" {
  description = "RDP command to connect to the Windows bastion host. Null when bastion is disabled."
  value       = var.bastion_enabled ? "mstsc /v:${aws_eip.bastion[0].public_ip}" : null
}

output "bastion_password_command" {
  description = "AWS CLI command to retrieve the Windows Administrator password. Requires the key pair private key."
  value       = var.bastion_enabled ? "aws ec2 get-password-data --instance-id ${aws_instance.bastion[0].id} --priv-launch-key ${var.bastion_key_name}.pem --query PasswordData --output text" : null
}

output "database_access_command" {
  description = "psql command to connect to Aurora PostgreSQL from the bastion. Retrieve password from Secrets Manager first."
  value       = var.bastion_enabled && var.create_database ? "psql -h ${module.litellm.aurora_writer_endpoint} -U ${var.db_master_username} -d ${var.db_name}" : null
  sensitive   = true
}
