# ============================================================================
# Main LiteLLM Infrastructure Module
# ============================================================================
# This file configures the official BerriAI/litellm/aws Terraform module to 
# deploy LiteLLM on AWS with ECS Fargate, Aurora PostgreSQL, ElastiCache Redis,
# and Application Load Balancer.
#
# Module source: https://registry.terraform.io/modules/BerriAI/litellm/aws
# GitHub: https://github.com/BerriAI/terraform-aws-litellm
#
# ============================================================================

module "litellm" {
  source  = "BerriAI/litellm/aws"
  version = "~> 1.89"

  # --------------------------------------------------------------------------
  # Required Core Variables
  # --------------------------------------------------------------------------
  region = var.aws_region
  tenant = var.tenant
  env    = var.environment

  # --------------------------------------------------------------------------
  # Networking Configuration
  # --------------------------------------------------------------------------
  # VPC settings - the module creates VPC networking internally when vpc_id,
  # public_subnet_ids, and private_subnet_ids are not provided (the default).
  # 
  # The module creates:
  # - VPC with the vpc_cidr CIDR block (default: 10.0.0.0/16)
  # - Public subnets (one per AZ): for ALB and NAT Gateway
  # - Private subnets (one per AZ): for ECS tasks, Aurora, and ElastiCache
  # - Internet Gateway: routes public subnet traffic to the internet
  # - NAT Gateway (single): routes private subnet outbound traffic to internet
  # - Route tables: public subnets → IGW, private subnets → NAT Gateway
  #
  # At least 2 AZs are required because Aurora and ElastiCache subnet groups
  # require subnets in multiple AZs. For cost optimization, use 2 AZs rather
  # than 3+, and configure Aurora with a single instance (no replicas).
  #
  # --------------------------------------------------------------------------
  vpc_cidr = var.vpc_cidr
  azs      = var.availability_zones

  # --------------------------------------------------------------------------
  # APPLICATION LOAD BALANCER CONFIGURATION
  # --------------------------------------------------------------------------
  # The module creates a complete ALB setup with:
  #
  # ALB RESOURCES:
  # - Internet-facing ALB in public subnets
  # - Security group allowing ports 80/443 from 0.0.0.0/0
  # - Target groups for Gateway (4000), Backend (4001), UI (3000)
  #
  # TLS/HTTPS:
  # - HTTPS listener on 443 when acm_certificate_arn is provided
  # - HTTP to HTTPS redirect (301) when TLS enabled
  # - SSL Policy: ELBSecurityPolicy-TLS13-1-2-2021-06
  #
  # HEALTH CHECKS:
  # - Path: /health/readiness (Gateway/Backend), /healthz (UI)
  # - Interval: 30s, Timeout: 10s (Gateway/Backend) / 5s (UI)
  # - Thresholds: 2 healthy, 3 unhealthy
  #
  # ROUTING RULES:
  # - Priority 10: Exact UI paths (/, /ui, /favicon.ico) → UI service
  # - Priority 20: UI prefixes (/_next/*, /ui/*, /assets/*) → UI service
  # - Priority 100+: API paths (/v1/*, /health*, etc.) → Gateway service
  # - Default: All other paths → Backend service (management API)
  #
  # LOAD BALANCING:
  # - Round-robin distribution across healthy targets
  # - Deregistration delay: 30 seconds
  #
  # NOTE: Sticky sessions are NOT enabled by the module.
  # For most deployments with ui_desired_count = 1, this has no impact.
  # See alb.tf for detailed documentation and workarounds.
  #
  # --------------------------------------------------------------------------
  # Certificate ARN: Use the effective certificate ARN from dns.tf
  # This allows either:
  # 1. A newly created certificate (when create_acm_certificate = true)
  # 2. A pre-existing certificate ARN (when create_acm_certificate = false)
  acm_certificate_arn = local.effective_certificate_arn
  allow_plaintext_alb = var.allow_plaintext_alb

  # --------------------------------------------------------------------------
  # Container Images
  # --------------------------------------------------------------------------
  # Pin to specific versions for production stability
  gateway_image    = var.litellm_gateway_image
  backend_image    = var.litellm_backend_image
  ui_image         = var.litellm_ui_image
  migrations_image = var.litellm_migrations_image

  # --------------------------------------------------------------------------
  # ECS FARGATE SERVICES CONFIGURATION
  # --------------------------------------------------------------------------
  # The BerriAI/litellm module creates a complete ECS Fargate deployment with:
  #
  # ECS CLUSTER:
  # - ECS Fargate cluster with Container Insights enabled
  # - Gateway Service: LiteLLM proxy container for API requests (port 4000)
  # - Backend Service: Background processing and management API (port 4001)
  # - UI Service: Admin dashboard (port 3000, static nginx)
  # - Migrations Task: One-off Prisma migration task for schema updates
  #
  # TASK DEFINITIONS:
  # - Configurable CPU and memory allocations per service
  # - CloudWatch Logs log driver for centralized logging
  # - awsvpc network mode with private subnet placement
  # - Official LiteLLM Docker images from GHCR
  #
  # HEALTH CHECKS:
  # - ALB health checks on /health/readiness endpoint
  # - Automatic task replacement when health checks fail
  # - 30s interval, 5s timeout, 2 healthy / 3 unhealthy thresholds
  #
  # ENVIRONMENT AND SECRETS:
  # - Database: IAM authentication via DATABASE_HOST/PORT/USER/NAME env vars
  #   (IAM_TOKEN_DB_AUTH=true enables token-based auth without passwords)
  # - Redis: REDIS_HOST/PORT/SSL env vars (transit_encryption_enabled = true)
  # - S3 Config: LITELLM_PROXY_CONFIG_S3_BUCKET/KEY for config.yaml
  # - Secrets: LITELLM_MASTER_KEY from Secrets Manager
  # - Provider Keys: Via gateway_extra_secrets (OPENAI_API_KEY, etc.)
  #
  # IAM ROLES:
  # - Task Execution Role: Pulls images, writes logs, retrieves secrets
  # - Task Role: RDS IAM connect, S3 bucket access
  # - Bedrock access: Added via ecs_iam.tf when enable_bedrock_access=true
  # --------------------------------------------------------------------------

  # --------------------------------------------------------------------------
  # Gateway Service Sizing and Autoscaling
  # --------------------------------------------------------------------------
  # AUTOSCALING CONFIGURATION:
  #
  # The BerriAI module implements Application Auto Scaling with target-tracking
  # policies that scale the gateway service based on:
  # - CPU utilization (default 70% target)
  # - ALB request count per target (via gateway_target_requests_per_second)
  # - Memory utilization (optional) - Additional stability metric
  #
  # SCALING BEHAVIOR:
  # - Scale-out: Application Auto Scaling adds tasks when any metric exceeds target
  # - Scale-in: Tasks are removed when ALL metrics are below target
  # - Multiple policies: The policy requesting the most capacity wins
  #
  # COOLDOWN PERIODS:
  # The BerriAI module uses AWS-managed cooldowns through target tracking:
  # - Target tracking policies have built-in scale-in cooldown (~300s)
  # - Target tracking policies have built-in scale-out cooldown (~60s)
  # These cannot be customized via the module but match the design requirements.
  #
  # CAPACITY LIMITS:
  # - Minimum tasks: gateway_min_capacity (prevents scale-to-zero)
  # - Maximum tasks: gateway_max_capacity (cost control)
  # --------------------------------------------------------------------------
  gateway_cpu           = var.gateway_cpu
  gateway_memory        = var.gateway_memory
  gateway_desired_count = var.gateway_desired_count

  # Autoscaling configuration
  gateway_autoscaling_enabled = var.gateway_autoscaling_enabled
  gateway_min_capacity        = var.gateway_min_capacity
  gateway_max_capacity        = var.gateway_max_capacity
  gateway_cpu_target          = var.gateway_cpu_target
  gateway_memory_target       = var.gateway_memory_target

  # ALB request count per target scaling
  # Set to 0 to disable; set to target RPS (e.g., 100) to enable
  gateway_target_requests_per_second = var.gateway_target_requests_per_second

  # Connection pooling for high throughput
  gateway_connection_pool_enabled = var.gateway_connection_pool_enabled
  gateway_pool_max_db_connections = var.gateway_pool_max_db_connections
  gateway_pool_max_client_conn    = var.gateway_pool_max_client_conn
  gateway_num_workers             = var.gateway_num_workers

  # --------------------------------------------------------------------------
  # Backend Service Sizing and Autoscaling
  # --------------------------------------------------------------------------
  # FIXED COUNT CONFIGURATION:
  #
  # The backend service handles background processing tasks like spend tracking,
  # batch operations, and the management API. For predictable operation:
  # - backend_autoscaling_enabled defaults to false
  # - backend_desired_count sets the fixed task count
  #
  # When autoscaling is disabled, the service maintains a constant number of
  # tasks regardless of load, ensuring consistent background processing capacity.
  # --------------------------------------------------------------------------
  backend_cpu           = var.backend_cpu
  backend_memory        = var.backend_memory
  backend_desired_count = var.backend_desired_count

  backend_autoscaling_enabled = var.backend_autoscaling_enabled
  backend_min_capacity        = var.backend_min_capacity
  backend_max_capacity        = var.backend_max_capacity
  backend_cpu_target          = var.backend_cpu_target

  # --------------------------------------------------------------------------
  # UI Service Sizing
  # --------------------------------------------------------------------------
  ui_cpu           = var.ui_cpu
  ui_memory        = var.ui_memory
  ui_desired_count = var.ui_desired_count

  # --------------------------------------------------------------------------
  # Database Configuration (Aurora PostgreSQL)
  # --------------------------------------------------------------------------
  # The BerriAI/litellm module automatically configures Aurora PostgreSQL with
  # enterprise security features:
  #
  # - IAM Database Authentication: iam_database_authentication_enabled = true
  #   ECS tasks authenticate via IAM roles, no stored database passwords.
  #
  # - Encryption at Rest (KMS): storage_encrypted = true
  #   All data at rest is encrypted using AWS KMS.
  #
  # - Encryption in Transit (TLS): Aurora PostgreSQL enforces TLS by default.
  #   All connections are encrypted in transit.
  #
  # - Automated Backups (7-day retention): backup_retention_period = 7
  #   Daily automated backups with point-in-time recovery capability.
  #
  # - Master Password in Secrets Manager: Generated via random_password
  #   Stored securely for emergency admin/break-glass access only.
  #
  # The module creates writer + reader instances for high availability.
  # --------------------------------------------------------------------------
  create_database    = var.create_database
  db_instance_class  = var.db_instance_class
  db_engine_version  = var.db_engine_version
  db_name            = var.db_name
  db_master_username = var.db_master_username
  db_username        = var.db_username

  # Safety settings - set skip_final_snapshot = false for production to ensure
  # a final snapshot is created before cluster deletion
  skip_final_snapshot = var.skip_final_snapshot

  # --------------------------------------------------------------------------
  # Cache Configuration (ElastiCache Redis)
  # --------------------------------------------------------------------------
  # The BerriAI module configures Redis with security features automatically:
  # - at_rest_encryption_enabled = true (KMS encryption)
  # - transit_encryption_enabled = true (TLS in transit + Redis AUTH)
  # - REDIS_SSL=true in ECS tasks (uses rediss:// connection scheme)
  # --------------------------------------------------------------------------
  create_redis       = var.create_redis
  redis_node_type    = var.redis_node_type
  redis_num_replicas = var.redis_num_replicas

  # --------------------------------------------------------------------------
  # S3 Configuration
  # --------------------------------------------------------------------------
  s3_force_destroy = var.s3_force_destroy

  # --------------------------------------------------------------------------
  # Secrets Configuration
  # --------------------------------------------------------------------------
  # Master key can be pre-set or auto-generated
  litellm_master_key = var.litellm_master_key

  # Enterprise license (optional)
  litellm_license = var.litellm_license

  # UI password (optional - falls back to master key if not set)
  ui_password = var.ui_password

  # --------------------------------------------------------------------------
  # LiteLLM Proxy Configuration (config.yaml)
  # --------------------------------------------------------------------------
  # Pass proxy configuration as a typed map
  # This gets uploaded to S3 and mounted by the containers
  proxy_config = var.proxy_config

  # --------------------------------------------------------------------------
  # Extra Environment Variables
  # --------------------------------------------------------------------------
  gateway_extra_env = var.gateway_extra_env
  backend_extra_env = var.backend_extra_env

  # --------------------------------------------------------------------------
  # Extra Secrets (Provider API Keys)
  # --------------------------------------------------------------------------
  # Map of env var name to Secrets Manager ARN
  # Merges the provider API key secrets created in secrets.tf with any
  # additional user-provided secrets. User-provided secrets take precedence.
  gateway_extra_secrets = merge(local.provider_secrets, var.gateway_extra_secrets)
  backend_extra_secrets = merge(local.provider_secrets, var.backend_extra_secrets)

  # --------------------------------------------------------------------------
  # CLOUDWATCH LOGGING CONFIGURATION
  # --------------------------------------------------------------------------
  # The BerriAI/litellm module creates CloudWatch Log Groups for all ECS
  # services automatically. No additional cloudwatch.tf file is needed.
  #
  # LOG GROUPS CREATED BY MODULE:
  # - /ecs/{tenant}-litellm-{env}/gateway   - Gateway service logs (port 4000)
  # - /ecs/{tenant}-litellm-{env}/backend   - Backend service logs (port 4001)
  # - /ecs/{tenant}-litellm-{env}/ui        - UI service logs (port 3000)
  # - /ecs/{tenant}-litellm-{env}/migrations - Database migration task logs
  #
  # LOG DRIVER CONFIGURATION:
  # - Driver: awslogs (CloudWatch Logs)
  # - Stream prefix: service name (gateway, backend, ui, migrations)
  # - Region: var.aws_region (passed via var.region to module)
  #
  # CONTAINER INSIGHTS:
  # - ECS cluster has Container Insights enabled for enhanced monitoring
  # - Provides CPU, memory, network, and storage metrics at task level
  #
  # --------------------------------------------------------------------------
  log_retention_days = var.cloudwatch_log_retention_days

  # --------------------------------------------------------------------------
  # Additional Tags
  # --------------------------------------------------------------------------
  tags = var.additional_tags
}
