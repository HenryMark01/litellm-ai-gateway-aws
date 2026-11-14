# LiteLLM AWS Production Deployment

This repository contains Terraform configuration for deploying LiteLLM proxy on AWS using the official [BerriAI/litellm/aws](https://registry.terraform.io/modules/BerriAI/litellm/aws) Terraform module.

## Architecture Overview

The deployment follows a **two-phase approach**:

1. **Bootstrap Phase**: Creates foundational S3 buckets for Terraform state and LiteLLM configuration storage, plus IAM deployment policies
2. **Main Phase**: Provisions complete LiteLLM infrastructure using the official Terraform module

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AWS Account                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                         Public Subnet                                │    │
│  │  ┌──────────────────┐                                               │    │
│  │  │ Application Load │◄───── HTTPS (443)                             │    │
│  │  │    Balancer      │                                               │    │
│  │  └────────┬─────────┘                                               │    │
│  │           │                    ┌─────────────┐                      │    │
│  │           │                    │ NAT Gateway │──► Internet          │    │
│  │           │                    └─────────────┘                      │    │
│  └───────────┼──────────────────────────────────────────────────────────┘   │
│              │                                                              │
│  ┌───────────┼──────────────────────────────────────────────────────────┐   │
│  │           ▼              Private Subnet                               │   │
│  │  ┌────────────────────────────────────────────┐                      │   │
│  │  │           ECS Fargate Cluster              │                      │   │
│  │  │  ┌──────────┐  ┌──────────┐  ┌──────────┐ │                      │   │
│  │  │  │ Gateway  │  │ Backend  │  │    UI    │ │                      │   │
│  │  │  │ Service  │  │ Service  │  │ Service  │ │                      │   │
│  │  │  └────┬─────┘  └────┬─────┘  └──────────┘ │                      │   │
│  │  └───────┼─────────────┼──────────────────────┘                      │   │
│  │          │             │                                             │   │
│  │          ▼             ▼                                             │   │
│  │  ┌──────────────┐  ┌──────────────┐                                 │   │
│  │  │Aurora        │  │ ElastiCache  │                                 │   │
│  │  │PostgreSQL    │  │    Redis     │                                 │   │
│  │  └──────────────┘  └──────────────┘                                 │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                      Supporting Services                             │    │
│  │  • Secrets Manager (API keys, master key)                           │    │
│  │  • S3 Config Bucket (config.yaml)                                   │    │
│  │  • S3 State Bucket (Terraform state)                                │    │
│  │  • CloudWatch (logs, alarms)                                        │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

### Required Software

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | **1.10+** | Infrastructure provisioning (required for S3 native locking) |
| AWS CLI | v2 | AWS credential management and resource inspection |

### AWS Credentials

You need AWS credentials with sufficient permissions to create the infrastructure. The bootstrap module creates IAM policies that define the minimum required permissions.

**Option 1: AWS CLI Profile**
```bash
aws configure --profile litellm-deploy
export AWS_PROFILE=litellm-deploy
```

**Option 2: Environment Variables**
```bash
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_REGION="us-east-1"
```

**Option 3: IAM Role (CI/CD)**

For CI/CD pipelines, use IAM roles with the deployment policies created by the bootstrap module.

### LLM Provider API Keys (Optional - Only for Direct API Access)

LiteLLM supports two ways to access LLM models:

| Method | Authentication | When to Use |
|--------|---------------|-------------|
| **AWS Bedrock** | IAM credentials (automatic) | Claude, Llama, Titan models via AWS |
| **Direct API** | Provider API keys | OpenAI, Anthropic direct (non-AWS) |

**If you're only using AWS Bedrock models** (recommended for AWS deployments), you don't need any API keys. The ECS task role automatically gets Bedrock permissions.

**If you also want direct OpenAI/Anthropic API access** (separate from Bedrock), export these before running Terraform:

```bash
# Only needed for direct API access, NOT for Bedrock
export TF_VAR_openai_api_key="sk-..."        # From platform.openai.com
export TF_VAR_anthropic_api_key="sk-ant-..." # From console.anthropic.com
```

These keys get stored in AWS Secrets Manager and injected into the ECS containers.

## Directory Structure

```
terraform/
├── bootstrap/              # Phase 1: State bucket and IAM policies
│   ├── main.tf            # S3 buckets and IAM policy resources
│   ├── variables.tf       # Input variables
│   ├── outputs.tf         # Bucket names and policy ARNs
│   ├── versions.tf        # Provider version constraints
│   └── terraform.tfvars   # Environment-specific values
├── main/                   # Phase 2: LiteLLM infrastructure
│   ├── main.tf            # BerriAI/litellm/aws module configuration
│   ├── backend.tf         # S3 backend configuration
│   ├── variables.tf       # Input variables
│   ├── outputs.tf         # Endpoint URLs and resource identifiers
│   └── versions.tf        # Provider version constraints
├── environments/           # Environment-specific variable files
│   └── staging.tfvars     # Staging environment configuration
└── README.md              # This file

configs/
└── config.yaml            # LiteLLM proxy configuration
```

## Deployment Instructions

### Phase 1: Bootstrap Deployment

The bootstrap module creates the S3 buckets for Terraform state and LiteLLM configuration, plus IAM deployment policies.

> **Note**: Bootstrap uses local state and should only be run once per environment.

#### 1.1 Configure Bootstrap Variables

Create or edit `terraform/bootstrap/terraform.tfvars`:

```hcl
# Required variables
tenant      = "mycompany"     # Your organization identifier
environment = "staging"       # Environment name (staging, production)
aws_region  = "us-east-1"     # AWS region

# Optional overrides
# state_bucket_name  = "custom-state-bucket-name"
# config_bucket_name = "custom-config-bucket-name"
# noncurrent_version_expiration_days = 90
```

#### 1.2 Initialize and Apply Bootstrap

```bash
cd terraform/bootstrap

# Initialize Terraform
terraform init

# Review the plan
terraform plan

# Apply (creates S3 buckets and IAM policies)
terraform apply
```

#### 1.3 Note the Outputs

After successful apply, note the outputs for configuring the main module:

```bash
terraform output
```

Example outputs:
```
state_bucket_name = "mycompany-staging-litellm-state"
config_bucket_name = "mycompany-staging-litellm-config"
deployment_policy_arns = [
  "arn:aws:iam::123456789012:policy/mycompany-staging-litellm-deploy-core",
  "arn:aws:iam::123456789012:policy/mycompany-staging-litellm-deploy-network",
  "arn:aws:iam::123456789012:policy/mycompany-staging-litellm-deploy-support"
]
```

### Phase 2: Main Infrastructure Deployment

#### 2.1 Configure Backend

Edit `terraform/main/backend.tf` to use your bootstrap bucket:

```hcl
terraform {
  backend "s3" {
    # Update these values with your tenant/environment
    bucket = "mycompany-staging-litellm-state"
    key    = "mycompany/litellm/staging/terraform.tfstate"
    region = "us-east-1"
    
    # Required settings (do not change)
    encrypt      = true
    use_lockfile = true  # Terraform 1.10+ native S3 locking
  }
}
```

#### 2.2 Create Environment Variables File

Create or copy the environment file:

```bash
cp terraform/environments/staging.tfvars terraform/environments/myenv.tfvars
```

Edit the file with your configuration. Key variables:

```hcl
# Core Configuration (must match bootstrap)
tenant      = "mycompany"
environment = "staging"
aws_region  = "us-east-1"

# Availability zones (minimum 2 required for Aurora and ALB)
availability_zones = ["us-east-1a", "us-east-1b"]

# Networking
vpc_cidr = "10.0.0.0/16"

# TLS Configuration (choose one option)
# Option 1: HTTP-only (development/internal)
allow_plaintext_alb = true
acm_certificate_arn = ""

# Option 2: Use existing ACM certificate
# allow_plaintext_alb = false
# acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/xxx"

# Option 3: Create new ACM certificate (requires domain)
# create_acm_certificate = true
# domain_name    = "api.example.com"
# hosted_zone_id = "Z1234567890ABC"

# Database (Aurora PostgreSQL)
create_database   = true
db_instance_class = "db.t4g.medium"  # ~$50/month
db_name           = "litellm"

# Cache (ElastiCache Redis)
create_redis    = true
redis_node_type = "cache.t4g.micro"  # ~$9/month

# ECS Service Sizing
gateway_cpu    = 512
gateway_memory = 2048
gateway_autoscaling_enabled = true
gateway_min_capacity = 1
gateway_max_capacity = 5
```

See `terraform/environments/staging.tfvars` for a complete example with all options.

#### 2.3 Initialize and Apply Main Infrastructure

```bash
cd terraform/main

# Initialize with the S3 backend
terraform init

# Review the plan
terraform plan -var-file=../environments/staging.tfvars

# Apply the infrastructure
terraform apply -var-file=../environments/staging.tfvars
```

The deployment takes approximately 15-25 minutes due to Aurora and ElastiCache provisioning.

#### 2.4 Note the Outputs

```bash
terraform output
```

Key outputs include:
- `alb_dns_name` - Load balancer endpoint for API access
- `litellm_endpoint` - Full HTTP/HTTPS endpoint URL
- `database_endpoint` - Aurora cluster endpoint
- `ecs_cluster_name` - ECS cluster for debugging

### Phase 3: Upload LiteLLM Configuration

The LiteLLM proxy loads its configuration from S3. Upload your `config.yaml`:

#### 3.1 Review the Configuration

The configuration file is located at `configs/config.yaml`. Review and customize:

- **Model routing**: Add your LLM providers and models
- **Prompt caching**: Enabled by default for cost optimization
- **Retry settings**: Configure retry behavior for reliability
- **Router settings**: Load balancing and failover configuration

```yaml
# configs/config.yaml - Key sections:

model_list:
  - model_name: "bedrock/*"
    litellm_params:
      model: "bedrock/*"
      aws_role_name: "arn:aws:iam::TARGET_ACCOUNT:role/BedrockAccessRole"
      aws_region_name: "us-east-1"

litellm_settings:
  enable_anthropic_prompt_caching: true
  num_retries: 3
  request_timeout: 300

general_settings:
  store_model_in_db: true
  master_key: "os.environ/LITELLM_MASTER_KEY"
```

#### 3.2 Upload to S3

```bash
# Upload config.yaml to the config bucket
aws s3 cp configs/config.yaml s3://mycompany-staging-litellm-config/config.yaml

# Verify the upload
aws s3 ls s3://mycompany-staging-litellm-config/
```

#### 3.3 Restart ECS Services to Load New Config

After uploading a new configuration, force a new deployment to reload:

```bash
# Get cluster and service names from Terraform outputs
CLUSTER=$(cd terraform/main && terraform output -raw ecs_cluster_name)

# Force new deployment of gateway service
aws ecs update-service \
  --cluster $CLUSTER \
  --service ${CLUSTER}-gateway \
  --force-new-deployment

# Optionally restart backend service
aws ecs update-service \
  --cluster $CLUSTER \
  --service ${CLUSTER}-backend \
  --force-new-deployment
```

## Environment Variables Reference

### Terraform Variables (via TF_VAR_*)

Set these as environment variables before running `terraform apply`:

| Variable | Required | Description |
|----------|----------|-------------|
| `TF_VAR_openai_api_key` | No | OpenAI API key for GPT models |
| `TF_VAR_anthropic_api_key` | No | Anthropic API key for Claude (direct, not Bedrock) |

Example:
```bash
export TF_VAR_openai_api_key="sk-..."
export TF_VAR_anthropic_api_key="sk-ant-..."
terraform apply -var-file=../environments/staging.tfvars
```

### LiteLLM Runtime Environment Variables

These are automatically configured by the BerriAI module in ECS task definitions:

| Variable | Source | Description |
|----------|--------|-------------|
| `LITELLM_MASTER_KEY` | Secrets Manager | Admin API key (auto-generated or provided) |
| `LITELLM_SALT_KEY` | Secrets Manager | Hashing salt (auto-generated) |
| `DATABASE_HOST` | Aurora endpoint | PostgreSQL connection host |
| `DATABASE_PORT` | `5432` | PostgreSQL port |
| `DATABASE_USER` | `litellm_app` | IAM-authenticated database user |
| `DATABASE_NAME` | `litellm` | Database name |
| `REDIS_HOST` | ElastiCache endpoint | Redis connection host |
| `REDIS_PORT` | `6379` | Redis port |
| `REDIS_SSL` | `true` | Enable TLS for Redis |
| `LITELLM_PROXY_CONFIG_S3_BUCKET` | Config bucket | S3 bucket for config.yaml |
| `LITELLM_PROXY_CONFIG_S3_KEY` | `config.yaml` | S3 key for config file |
| `OPENAI_API_KEY` | Secrets Manager | OpenAI API key (if provided) |
| `ANTHROPIC_API_KEY` | Secrets Manager | Anthropic API key (if provided) |

### Config.yaml Environment References

In `config.yaml`, reference secrets using `os.environ/` syntax:

```yaml
general_settings:
  master_key: "os.environ/LITELLM_MASTER_KEY"

model_list:
  - model_name: "gpt-4"
    litellm_params:
      model: "openai/gpt-4"
      api_key: "os.environ/OPENAI_API_KEY"
```

## Updating Configuration

### Update config.yaml

1. Edit `configs/config.yaml`
2. Upload to S3: `aws s3 cp configs/config.yaml s3://<config-bucket>/config.yaml`
3. Force ECS redeployment (see Phase 3.3 above)

### Update Infrastructure

1. Edit the `.tfvars` file or Terraform configurations
2. Run `terraform plan -var-file=../environments/staging.tfvars` to review changes
3. Run `terraform apply -var-file=../environments/staging.tfvars` to apply

### Rotate Secrets

Secrets are stored in AWS Secrets Manager. To rotate:

1. Update the secret value in Secrets Manager console or CLI
2. Force ECS redeployment to pick up new values

## Verification

### Check ECS Service Health

```bash
# Get cluster name
CLUSTER=$(cd terraform/main && terraform output -raw ecs_cluster_name)

# List services
aws ecs list-services --cluster $CLUSTER

# Describe gateway service
aws ecs describe-services --cluster $CLUSTER --services ${CLUSTER}-gateway
```

### Check LiteLLM Health

```bash
# Get endpoint
ENDPOINT=$(cd terraform/main && terraform output -raw litellm_endpoint)

# Health check
curl "${ENDPOINT}/health/liveliness"

# Test with API key
curl -X POST "${ENDPOINT}/v1/chat/completions" \
  -H "Authorization: Bearer sk-your-master-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bedrock/anthropic.claude-3-sonnet-20240229-v1:0",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

### View Logs

```bash
# Gateway logs
aws logs tail /ecs/${CLUSTER}/gateway --follow

# Backend logs
aws logs tail /ecs/${CLUSTER}/backend --follow
```

## Troubleshooting

### Common Issues

**1. Terraform init fails with backend error**
- Ensure the bootstrap module has been applied first
- Verify the bucket name in `backend.tf` matches the bootstrap output
- Check AWS credentials have S3 access

**2. ECS tasks failing to start**
- Check CloudWatch logs for container errors
- Verify Secrets Manager secrets exist and are accessible
- Confirm S3 config bucket has config.yaml

**3. Database connection errors**
- IAM database authentication requires proper task role permissions
- Ensure security groups allow traffic on port 5432
- For manual access, use the bastion host with master password

**4. Config changes not taking effect**
- Upload new config.yaml to S3
- Force ECS redeployment to reload configuration

## Cost Estimation

Estimated monthly costs for a minimal staging deployment:

| Resource | Configuration | Est. Cost |
|----------|--------------|-----------|
| Aurora PostgreSQL | db.t4g.medium | ~$50/month |
| ElastiCache Redis | cache.t4g.micro | ~$9/month |
| ECS Fargate | 1 gateway + 1 backend task | ~$15-25/month |
| NAT Gateway | Single NAT | ~$35/month |
| ALB | Basic usage | ~$20/month |
| **Total** | | **~$130-140/month** |

*Note: Costs vary by region and usage. LLM API costs are additional.*

## Security Considerations

- All data encrypted at rest (KMS) and in transit (TLS)
- IAM database authentication (no stored credentials)
- Secrets stored in AWS Secrets Manager
- Private subnets for all compute and data resources
- Security groups enforce least-privilege access
- S3 buckets block public access

## References

- [BerriAI/litellm/aws Terraform Module](https://registry.terraform.io/modules/BerriAI/litellm/aws)
- [LiteLLM Documentation](https://docs.litellm.ai/)
- [LiteLLM Proxy Configuration](https://docs.litellm.ai/docs/proxy/configs)
- [Terraform S3 Backend](https://developer.hashicorp.com/terraform/language/settings/backends/s3)
