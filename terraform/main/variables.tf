# ============================================================================
# Main LiteLLM Module Variables
# ============================================================================
# These variables are used to configure the LiteLLM infrastructure deployment
# using the official BerriAI/litellm/aws Terraform module.
#
# ============================================================================

# --------------------------------------------------------------------------
# Core Variables (Required)
# --------------------------------------------------------------------------

variable "tenant" {
  description = "Tenant identifier for resource naming. Used as a prefix for all resources. Combined with environment to form resource names like {tenant}-litellm-{env}."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,20}$", var.tenant))
    error_message = "Tenant must be 1-21 characters, lowercase alphanumeric with hyphens allowed, starting with a letter."
  }
}

variable "environment" {
  description = "Environment name for resource isolation (e.g., staging, prod, dev). Used to suffix all resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,8}$", var.environment))
    error_message = "Environment must be 1-9 characters, lowercase alphanumeric with hyphens allowed, starting with a letter."
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

variable "availability_zones" {
  description = <<-EOT
    List of availability zones to spread subnets across.
    
    IMPORTANT: At least 2 AZs are REQUIRED because:
    - Aurora PostgreSQL subnet groups require subnets in at least 2 AZs
    - Application Load Balancer requires subnets in at least 2 AZs
    - ElastiCache subnet groups require subnets in at least 2 AZs
    
    For cost-optimized single-AZ deployment, the module creates subnets in
    all provided AZs but ECS tasks, Aurora writer, and ElastiCache primary
    can all land in the same AZ. The second AZ provides failover capability
    and satisfies AWS service requirements.
    
    Example for us-east-1: ["us-east-1a", "us-east-1b"]
  EOT
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least 2 availability zones are required for Aurora and ALB."
  }
}

# --------------------------------------------------------------------------
# Networking Configuration
# --------------------------------------------------------------------------
# The BerriAI/litellm/aws module creates VPC networking internally when
# vpc_id is not provided (the default). This includes:
# - VPC with the configured CIDR block
# - Public subnets (one per AZ) for ALB and NAT Gateway
# - Private subnets (one per AZ) for ECS, Aurora, and ElastiCache
# - Internet Gateway for public subnet internet access
# - Single NAT Gateway for private subnet outbound access
# - Route tables connecting public subnets to IGW and private subnets to NAT
#
# --------------------------------------------------------------------------

variable "vpc_cidr" {
  description = <<-EOT
    CIDR block for the VPC created by the module.
    The module creates public subnets using cidrsubnet(vpc_cidr, 8, 0..N)
    and private subnets using cidrsubnet(vpc_cidr, 8, 10..10+N).
    
    With the default 10.0.0.0/16:
    - Public subnet 1:  10.0.0.0/24 (ALB, NAT Gateway)
    - Public subnet 2:  10.0.1.0/24 (ALB)
    - Private subnet 1: 10.0.10.0/24 (ECS, Aurora, ElastiCache)
    - Private subnet 2: 10.0.11.0/24 (ECS, Aurora, ElastiCache)
    
    Only used when the module creates the VPC (vpc_id not provided to module).
  EOT
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block."
  }
}

# --------------------------------------------------------------------------
# TLS/HTTPS Configuration
# --------------------------------------------------------------------------

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for HTTPS on the ALB. Leave empty for HTTP-only mode (requires allow_plaintext_alb = true)."
  type        = string
  default     = ""
}

variable "allow_plaintext_alb" {
  description = "Allow HTTP-only mode on ALB (no TLS). Set to true only for dev/trial environments."
  type        = bool
  default     = false
}

# --------------------------------------------------------------------------
# DNS and Domain Configuration
# --------------------------------------------------------------------------
# Configuration for custom domain, Route53 DNS records, and ACM certificate
# creation. These variables are optional - if not provided, the ALB DNS name
# is used directly.
#
# --------------------------------------------------------------------------

variable "domain_name" {
  description = <<-EOT
    Custom domain name for the LiteLLM endpoint (e.g., "api.example.com").
    
    USAGE PATTERNS:
    - Leave empty (default): Use ALB DNS name directly, no custom domain
    - Set with hosted_zone_id: Automatic Route53 A record creation
    - Set without hosted_zone_id: Manual DNS configuration required
    
    When set, this domain will be used for:
    - ACM certificate subject (if create_acm_certificate = true)
    - Route53 A record (if hosted_zone_id is provided)
    - Output URLs and endpoint documentation
    
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.domain_name == "" || can(regex("^[a-z0-9][a-z0-9-]*(\\.[a-z0-9][a-z0-9-]*)+$", var.domain_name))
    error_message = "domain_name must be a valid domain name (e.g., 'api.example.com') or empty."
  }
}

variable "hosted_zone_id" {
  description = <<-EOT
    Route53 hosted zone ID for automatic DNS record management.
    
    USAGE PATTERNS:
    - Leave empty (default): No automatic DNS records; use ALB DNS or configure manually
    - Set with domain_name: Creates Route53 A record aliased to ALB
    - Set with create_acm_certificate: Creates DNS validation records automatically
    
    When provided, the following Route53 records are created:
    - A record aliased to ALB DNS name (for domain_name)
    - CNAME records for ACM certificate DNS validation (if create_acm_certificate = true)
    
    Find your hosted zone ID in the Route53 console or with:
      aws route53 list-hosted-zones --query "HostedZones[?Name=='example.com.'].Id"
    
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.hosted_zone_id == "" || can(regex("^Z[A-Z0-9]+$", var.hosted_zone_id))
    error_message = "hosted_zone_id must be a valid Route53 hosted zone ID (starts with 'Z') or empty."
  }
}

variable "create_acm_certificate" {
  description = <<-EOT
    Create a new ACM certificate for the domain_name.
    
    USAGE PATTERNS:
    - false (default): Use existing certificate via acm_certificate_arn variable
    - true: Create new certificate for domain_name (requires domain_name to be set)
    
    When true, an ACM certificate is created with DNS validation:
    - If hosted_zone_id is provided: Validation records created automatically
    - If hosted_zone_id is empty: Manual DNS configuration required
    
    The certificate ARN is automatically passed to the LiteLLM module when
    this is true, overriding any value in acm_certificate_arn.
    
    TIMEOUT HANDLING:
    Certificate validation may timeout (75 minutes) if DNS records are not
    accessible. Ensure DNS is properly configured before applying.
    
  EOT
  type        = bool
  default     = false
}

# --------------------------------------------------------------------------
# Container Images
# --------------------------------------------------------------------------

variable "litellm_gateway_image" {
  description = "Docker image for the LiteLLM gateway service (data plane, port 4000)."
  type        = string
  default     = "ghcr.io/berriai/litellm-gateway:main-stable"
}

variable "litellm_backend_image" {
  description = "Docker image for the LiteLLM backend service (management API, port 4001)."
  type        = string
  default     = "ghcr.io/berriai/litellm-backend:main-stable"
}

variable "litellm_ui_image" {
  description = "Docker image for the LiteLLM UI service (admin dashboard, port 3000)."
  type        = string
  default     = "ghcr.io/berriai/litellm-ui:main-stable"
}

variable "litellm_migrations_image" {
  description = "Docker image for the database migrations task."
  type        = string
  default     = "ghcr.io/berriai/litellm-migrations:main-stable"
}

# --------------------------------------------------------------------------
# Gateway Service Configuration
# --------------------------------------------------------------------------

variable "gateway_cpu" {
  description = "Fargate CPU units for the gateway task (1024 = 1 vCPU)."
  type        = number
  default     = 1024
}

variable "gateway_memory" {
  description = "Fargate memory (MiB) for the gateway task."
  type        = number
  default     = 4096
}

variable "gateway_desired_count" {
  description = "Initial desired number of gateway tasks."
  type        = number
  default     = 2
}

variable "gateway_num_workers" {
  description = "Number of uvicorn worker processes per gateway task."
  type        = number
  default     = 1

  validation {
    condition     = var.gateway_num_workers >= 1
    error_message = "gateway_num_workers must be >= 1."
  }
}

variable "gateway_connection_pool_enabled" {
  description = "Enable in-container PgBouncer connection pooling for the gateway."
  type        = bool
  default     = false
}

variable "gateway_pool_max_db_connections" {
  description = "Max database connections per gateway task when connection pooling is enabled."
  type        = number
  default     = 20
}

variable "gateway_pool_max_client_conn" {
  description = "Max client connections to PgBouncer when connection pooling is enabled."
  type        = number
  default     = 1000
}

# --------------------------------------------------------------------------
# Gateway Autoscaling Configuration
# --------------------------------------------------------------------------

variable "gateway_autoscaling_enabled" {
  description = "Enable Application Auto Scaling for the gateway service."
  type        = bool
  default     = true
}

variable "gateway_min_capacity" {
  description = "Minimum number of gateway tasks under autoscaling."
  type        = number
  default     = 1
}

variable "gateway_max_capacity" {
  description = "Maximum number of gateway tasks under autoscaling."
  type        = number
  default     = 10
}

variable "gateway_cpu_target" {
  description = "Target average CPU utilization (%) for gateway autoscaling."
  type        = number
  default     = 70
}

variable "gateway_memory_target" {
  description = "Target average memory utilization (%) for gateway autoscaling. Set 0 to disable memory-based scaling."
  type        = number
  default     = 80
}

variable "gateway_target_requests_per_second" {
  description = <<-EOT
    Target requests per second per gateway task for ALB-based autoscaling.
    
    Adds an ALBRequestCountPerTarget target-tracking policy alongside the
    CPU/memory policies. Application Auto Scaling follows whichever policy
    requests the most tasks.
    
    CloudWatch publishes ALBRequestCountPerTarget as a 1-minute count, so the
    policy targets 60x this value. ECS reacts on a ~1 minute cadence.
    
    Set to 0 (default) to disable request-based scaling and rely only on
    CPU/memory metrics.
    
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.gateway_target_requests_per_second >= 0
    error_message = "gateway_target_requests_per_second must be >= 0."
  }
}

# --------------------------------------------------------------------------
# Backend Service Configuration
# --------------------------------------------------------------------------

variable "backend_cpu" {
  description = "Fargate CPU units for the backend task (1024 = 1 vCPU)."
  type        = number
  default     = 1024
}

variable "backend_memory" {
  description = "Fargate memory (MiB) for the backend task."
  type        = number
  default     = 4096
}

variable "backend_desired_count" {
  description = "Desired number of backend tasks."
  type        = number
  default     = 1
}

variable "backend_autoscaling_enabled" {
  description = <<-EOT
    Enable Application Auto Scaling for the backend service.
    
    Set to false (default) to maintain a fixed task count for predictable
    background processing. The backend service handles asynchronous operations
    like spend tracking and batch jobs that benefit from consistent capacity.
    
    When disabled, backend_desired_count determines the fixed number of tasks.
    When enabled, scales between backend_min_capacity and backend_max_capacity
    based on backend_cpu_target.
    
  EOT
  type        = bool
  default     = false
}

variable "backend_min_capacity" {
  description = "Minimum number of backend tasks under autoscaling."
  type        = number
  default     = 1
}

variable "backend_max_capacity" {
  description = "Maximum number of backend tasks under autoscaling."
  type        = number
  default     = 4
}

variable "backend_cpu_target" {
  description = "Target average CPU utilization (%) for backend autoscaling."
  type        = number
  default     = 70
}

# --------------------------------------------------------------------------
# UI Service Configuration
# --------------------------------------------------------------------------

variable "ui_cpu" {
  description = "Fargate CPU units for the UI task."
  type        = number
  default     = 256
}

variable "ui_memory" {
  description = "Fargate memory (MiB) for the UI task."
  type        = number
  default     = 512
}

variable "ui_desired_count" {
  description = "Desired number of UI tasks."
  type        = number
  default     = 1
}

# --------------------------------------------------------------------------
# Database Configuration (Aurora PostgreSQL)
# --------------------------------------------------------------------------
# The BerriAI/litellm/aws module provisions Aurora PostgreSQL with the
# following security features ENABLED BY DEFAULT (no additional configuration
# required):
#
# SECURITY FEATURES:
# - IAM Database Authentication: ECS tasks authenticate using IAM roles
#   instead of stored credentials. The module sets:
#   `iam_database_authentication_enabled = true`
#
# - Encryption at Rest: Data is encrypted using AWS KMS. The module sets:
#   `storage_encrypted = true`
#
# - Encryption in Transit: TLS is enforced for all Aurora PostgreSQL
#   connections by default (Aurora PostgreSQL uses SSL/TLS by default).
#
# - Automated Backups: Daily backups retained for 7 days. The module sets:
#   `backup_retention_period = 7`
#   `preferred_backup_window = "07:00-09:00"`
#
# - Master Password in Secrets Manager: The module generates a secure
#   random password and stores it in Secrets Manager for emergency
#   admin access (break-glass scenarios).
#
# DEPLOYMENT MODEL:
# The module creates a writer instance and a reader instance by default.
# For cost-optimized single-instance deployment, note that the module
# always creates both instances - this is by design for failover capability.
#
# POST-DEPLOYMENT IAM USER SETUP:
# After initial deployment, the db_username (IAM-authenticated user) must
# be created manually by connecting as master user and running:
#   CREATE USER {db_username};
#   GRANT rds_iam TO {db_username};
#   GRANT ALL PRIVILEGES ON DATABASE {db_name} TO {db_username};
#   GRANT ALL ON SCHEMA public TO {db_username};
# --------------------------------------------------------------------------

variable "create_database" {
  description = <<-EOT
    Create Aurora PostgreSQL cluster. Set false to use existing database via database_url.
    When true, the module creates an Aurora PostgreSQL cluster with:
    - IAM database authentication enabled
    - KMS encryption at rest
    - TLS encryption in transit
    - 7-day automated backup retention
    - Master password stored in Secrets Manager
  EOT
  type        = bool
  default     = true
}

variable "db_instance_class" {
  description = <<-EOT
    Aurora instance class for the database. The module creates both a writer
    and reader instance using this class.
    
    Recommended sizes:
    - db.t4g.medium: Development/testing (2 vCPU, 4 GB RAM)
    - db.r6g.large: Production small (2 vCPU, 16 GB RAM)
    - db.r6g.xlarge: Production medium (4 vCPU, 32 GB RAM)
  EOT
  type        = string
  default     = "db.r6g.large"
}

variable "db_engine_version" {
  description = "Aurora PostgreSQL engine version. The module uses aurora-postgresql engine."
  type        = string
  default     = "16.4"
}

variable "db_name" {
  description = "Initial database name to create on the Aurora cluster."
  type        = string
  default     = "litellm"
}

variable "db_master_username" {
  description = <<-EOT
    Aurora master username for bootstrap operations and emergency admin access.
    The master password is auto-generated and stored in Secrets Manager.
    
    IMPORTANT: Use this only for:
    - Initial IAM user setup (granting rds_iam role)
    - Emergency break-glass database access
    - Schema migrations requiring superuser privileges
    
    Normal application connections use IAM authentication via db_username.
  EOT
  type        = string
  default     = "postgres"
}

variable "db_username" {
  description = <<-EOT
    IAM-authenticated Postgres user for ECS task connections.
    
    This user authenticates via IAM database authentication (no password stored).
    ECS tasks use their IAM task role to generate temporary auth tokens.
    
    POST-DEPLOYMENT SETUP REQUIRED:
    After initial deployment, connect as master user and run:
      CREATE USER {db_username};
      GRANT rds_iam TO {db_username};
      GRANT ALL PRIVILEGES ON DATABASE {db_name} TO {db_username};
      GRANT ALL ON SCHEMA public TO {db_username};
  EOT
  type        = string
  default     = "litellm_app"
}

variable "skip_final_snapshot" {
  description = <<-EOT
    Skip final snapshot on Aurora cluster destruction.
    
    - false (default): Creates a final snapshot before deletion (recommended for production)
    - true: Skips snapshot (use only for ephemeral/test environments)
    
    The snapshot name follows the pattern: {cluster-name}-final-{short-hash}
  EOT
  type        = bool
  default     = false
}

# --------------------------------------------------------------------------
# Cache Configuration (ElastiCache Redis)
# --------------------------------------------------------------------------
# The BerriAI/litellm/aws module creates an ElastiCache Redis replication group
# with the following security features ENABLED BY DEFAULT (hardcoded in module):
#
# SECURITY FEATURES (automatically configured by module):
# - KMS Encryption at Rest: at_rest_encryption_enabled = true
# - TLS Encryption in Transit: transit_encryption_enabled = true
# - Redis AUTH: Enforced via TLS (transit_encryption_enabled enables AUTH)
# - Connection Scheme: Uses rediss:// (TLS-enabled) scheme automatically
#
# The module sets REDIS_SSL=true in the ECS task environment, ensuring
# the LiteLLM proxy connects via the secure rediss:// protocol.
#
# Node configuration:
# - num_cache_clusters = 1 + redis_num_replicas
# - When redis_num_replicas = 0: Single-node cluster (cost-optimized)
# - When redis_num_replicas >= 1: Multi-node with automatic failover
#
# --------------------------------------------------------------------------

variable "create_redis" {
  description = <<-EOT
    Create ElastiCache Redis cluster. Set false to use existing Redis via redis_url.
    
    When true, the BerriAI module creates a Redis replication group with:
    - KMS encryption at rest (automatically enabled)
    - TLS encryption in transit (automatically enabled)
    - Redis AUTH via TLS (automatically enabled)
    - Private subnet placement (no public accessibility)
  EOT
  type        = bool
  default     = true
}

variable "redis_node_type" {
  description = <<-EOT
    ElastiCache node type for Redis.
    
    Recommended types:
    - cache.t4g.micro: Development/testing (~$9/month)
    - cache.t4g.small: Small production workloads (~$18/month)
    - cache.r6g.large: High-throughput production (~$90/month)
    
    T4G instances use ARM-based Graviton2 processors for cost efficiency.
  EOT
  type        = string
  default     = "cache.t4g.small"
}

variable "redis_num_replicas" {
  description = <<-EOT
    Number of Redis read replicas for high availability.
    
    Configuration options:
    - 0: Single-node cluster (cost-optimized, no HA)
         Total nodes = 1, no automatic failover
    - 1+: Multi-node with automatic failover and Multi-AZ
         Total nodes = 1 + redis_num_replicas
    
    For staging/dev environments: 0 (single-node)
    For production with HA requirements: 1-2 replicas
    
    Note: Even with 0 replicas, the module still enables:
    - KMS encryption at rest
    - TLS encryption in transit
    - Redis AUTH authentication
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.redis_num_replicas >= 0
    error_message = "redis_num_replicas must be >= 0."
  }
}

# --------------------------------------------------------------------------
# S3 Configuration
# --------------------------------------------------------------------------

variable "s3_force_destroy" {
  description = "Allow destroying S3 bucket even with objects. Set true only for ephemeral environments."
  type        = bool
  default     = false
}

# --------------------------------------------------------------------------
# Secrets Configuration
# --------------------------------------------------------------------------

variable "litellm_master_key" {
  description = "Pre-existing LITELLM_MASTER_KEY (must begin with 'sk-'). Empty = auto-generate."
  type        = string
  default     = ""
  sensitive   = true
}

variable "litellm_license" {
  description = "LiteLLM enterprise license string. Empty for OSS-only deployments."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ui_password" {
  description = "UI admin password. Empty falls back to master key for UI login."
  type        = string
  default     = ""
  sensitive   = true
}

variable "secrets_recovery_window_days" {
  description = <<-EOT
    Recovery window for Secrets Manager secrets (days).
    
    - 0: Immediate deletion (use for dev/test environments)
    - 7-30: Standard recovery window (recommended for production)
    
    When a secret is deleted, it enters a recovery window where it can be
    restored. Set to 0 for immediate deletion in non-production environments.
  EOT
  type        = number
  default     = 7

  validation {
    condition     = var.secrets_recovery_window_days == 0 || (var.secrets_recovery_window_days >= 7 && var.secrets_recovery_window_days <= 30)
    error_message = "secrets_recovery_window_days must be 0 (immediate deletion) or between 7 and 30 days."
  }
}

# --------------------------------------------------------------------------
# LiteLLM Proxy Configuration
# --------------------------------------------------------------------------

variable "proxy_config" {
  description = <<-EOT
    LiteLLM proxy configuration (contents of config.yaml) as a typed map.
    Uploaded to S3 and mounted by gateway/backend containers.
    Use "os.environ/<NAME>" syntax to reference environment variables.
    
    Example:
      proxy_config = {
        model_list = [
          {
            model_name = "bedrock/*"
            litellm_params = {
              model = "bedrock/*"
              aws_region_name = "us-east-1"
            }
          }
        ]
        general_settings = {
          master_key = "os.environ/LITELLM_MASTER_KEY"
        }
      }
  EOT
  type        = any
  default     = {}
}

# --------------------------------------------------------------------------
# Extra Environment Variables
# --------------------------------------------------------------------------

variable "gateway_extra_env" {
  description = "Additional plain-text environment variables for the gateway container."
  type        = map(string)
  default     = {}
}

variable "backend_extra_env" {
  description = "Additional plain-text environment variables for the backend container."
  type        = map(string)
  default     = {}
}

# --------------------------------------------------------------------------
# Provider API Keys
# --------------------------------------------------------------------------
# These variables store LLM provider API keys. The keys are stored in
# AWS Secrets Manager with resource policies restricting access to only
# the ECS task execution role.
#
# The secrets are automatically passed to the BerriAI module via
# gateway_extra_secrets, which grants IAM permissions and injects them
# into ECS task definitions.
# --------------------------------------------------------------------------

variable "openai_api_key" {
  description = <<-EOT
    OpenAI API key for GPT-4, GPT-4o, and other OpenAI models.
    
    This key is stored in Secrets Manager and injected into the gateway
    container as OPENAI_API_KEY environment variable.
    
    Referenced in config.yaml as:
      api_key: "os.environ/OPENAI_API_KEY"
    
    Leave empty if not using OpenAI models or using Azure OpenAI instead.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "anthropic_api_key" {
  description = <<-EOT
    Anthropic API key for direct Claude API access (not via AWS Bedrock).
    
    This key is stored in Secrets Manager and injected into the gateway
    container as ANTHROPIC_API_KEY environment variable.
    
    Referenced in config.yaml as:
      api_key: "os.environ/ANTHROPIC_API_KEY"
    
    Note: For Claude via AWS Bedrock, no API key is needed - use IAM roles
    via the task role's Bedrock permissions instead.
    
    Leave empty if only using Bedrock for Claude models.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

# --------------------------------------------------------------------------
# Extra Secrets (Additional Provider API Keys)
# --------------------------------------------------------------------------

variable "gateway_extra_secrets" {
  description = <<-EOT
    Additional secrets from AWS Secrets Manager for the gateway container.
    Map of env var name to Secrets Manager ARN.
    
    Use this for provider API keys beyond OpenAI and Anthropic.
    The openai_api_key and anthropic_api_key variables are automatically
    merged into this map.
    
    Example:
      gateway_extra_secrets = {
        COHERE_API_KEY = "arn:aws:secretsmanager:us-east-1:123456789:secret:cohere-key"
      }
  EOT
  type        = map(string)
  default     = {}
}

variable "backend_extra_secrets" {
  description = "Extra secrets from AWS Secrets Manager for the backend container."
  type        = map(string)
  default     = {}
}

# --------------------------------------------------------------------------
# Logging Configuration
# --------------------------------------------------------------------------

variable "cloudwatch_log_retention_days" {
  description = "CloudWatch log retention period in days."
  type        = number
  default     = 30
}

# --------------------------------------------------------------------------
# Security Group Configuration
# --------------------------------------------------------------------------

variable "alb_allowed_cidr_blocks" {
  description = <<-EOT
    CIDR blocks allowed to access the ALB on ports 80 and 443.
    NOTE: The BerriAI/litellm module currently hardcodes 0.0.0.0/0 for ALB ingress.
    This variable is defined for documentation purposes and future module updates.
    To restrict access, use AWS WAF or update the module's security group after deployment.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "bastion_enabled" {
  description = "Enable Windows bastion host for emergency database access. Creates a Windows Server EC2 instance in public subnet with RDP access."
  type        = bool
  default     = false
}

variable "bastion_allowed_rdp_cidr_blocks" {
  description = "CIDR blocks allowed to RDP to the Windows bastion host (port 3389). Should be restricted to admin IPs only."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.bastion_allowed_rdp_cidr_blocks, "0.0.0.0/0") || length(var.bastion_allowed_rdp_cidr_blocks) == 0
    error_message = "bastion_allowed_rdp_cidr_blocks should not contain 0.0.0.0/0 for security reasons. Restrict to specific admin IPs."
  }
}

variable "bastion_instance_type" {
  description = "EC2 instance type for the Windows bastion host. t3.micro (1 vCPU, 1 GB RAM) is minimal spec for occasional admin access."
  type        = string
  default     = "t3.micro"
}

variable "bastion_key_name" {
  description = "Name of the EC2 key pair for retrieving Windows Administrator password. Required when bastion_enabled is true."
  type        = string
  default     = ""
}

# --------------------------------------------------------------------------
# CloudWatch Alarms Configuration
# --------------------------------------------------------------------------
# Configuration for CloudWatch alarms monitoring critical metrics
# --------------------------------------------------------------------------

variable "enable_cloudwatch_alarms" {
  description = <<-EOT
    Enable CloudWatch alarms for critical metrics (CPU, memory, error rates, latency).
    
    When enabled, creates alarms for:
    - ECS Gateway service CPU utilization
    - ECS Gateway service memory utilization
    - ALB 5XX error rate (threshold > 5% over 5 minutes)
    - ALB request latency
    
  EOT
  type        = bool
  default     = true
}

variable "alarm_sns_topic_arn" {
  description = <<-EOT
    ARN of an existing SNS topic for CloudWatch alarm notifications.
    
    If empty (default), a new SNS topic will be created for alarm notifications.
    Provide an existing topic ARN to integrate with your existing notification
    infrastructure (e.g., PagerDuty, Slack, email subscriptions).
    
  EOT
  type        = string
  default     = ""
}

variable "cpu_alarm_threshold" {
  description = <<-EOT
    CPU utilization threshold (%) for ECS service alarms.
    
    An alarm triggers when average CPU utilization exceeds this threshold
    for 2 consecutive 5-minute periods (10 minutes total).
    
    Recommended values:
    - 70-80%: Conservative, early warning
    - 85%: Balanced (default)
    - 90%: Less sensitive, fewer false positives
  EOT
  type        = number
  default     = 85

  validation {
    condition     = var.cpu_alarm_threshold > 0 && var.cpu_alarm_threshold <= 100
    error_message = "cpu_alarm_threshold must be between 1 and 100."
  }
}

variable "memory_alarm_threshold" {
  description = <<-EOT
    Memory utilization threshold (%) for ECS service alarms.
    
    An alarm triggers when average memory utilization exceeds this threshold
    for 2 consecutive 5-minute periods (10 minutes total).
    
    Recommended values:
    - 70-80%: Conservative, early warning
    - 85%: Balanced (default)
    - 90%: Less sensitive, fewer false positives
  EOT
  type        = number
  default     = 85

  validation {
    condition     = var.memory_alarm_threshold > 0 && var.memory_alarm_threshold <= 100
    error_message = "memory_alarm_threshold must be between 1 and 100."
  }
}

variable "latency_alarm_threshold_seconds" {
  description = <<-EOT
    Latency threshold (seconds) for ALB response time alarms.
    
    An alarm triggers when average response time exceeds this threshold
    for 5 consecutive 1-minute periods (5 minutes total).
    
    Note: LLM API calls can have high latency due to model inference time.
    Set this value appropriately for your expected workload:
    - 2-3 seconds: Chat completions, fast responses
    - 5 seconds: Standard completions (default)
    - 10+ seconds: Long-form generation, complex prompts
  EOT
  type        = number
  default     = 5

  validation {
    condition     = var.latency_alarm_threshold_seconds > 0
    error_message = "latency_alarm_threshold_seconds must be greater than 0."
  }
}

# --------------------------------------------------------------------------
# Additional Tags
# --------------------------------------------------------------------------

variable "additional_tags" {
  description = "Additional tags to apply to all resources created by the module."
  type        = map(string)
  default     = {}
}
