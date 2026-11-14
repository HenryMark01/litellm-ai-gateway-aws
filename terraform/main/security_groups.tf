# ============================================================================
# Security Groups Configuration Documentation
# ============================================================================
# This file documents the security group architecture for the LiteLLM deployment.
# The BerriAI/litellm/aws module creates most security groups internally with
# least-privilege rules.
#
# ============================================================================
#
# SECURITY GROUP ARCHITECTURE (Created by BerriAI/litellm/aws module)
# ============================================================================
#
# The official module creates the following security groups in network.tf:
#
# 1. ALB Security Group (aws_security_group.alb)
#    ├── Ingress: Port 80 (HTTP) from 0.0.0.0/0
#    ├── Ingress: Port 443 (HTTPS) from 0.0.0.0/0
#    └── Egress: All traffic to 0.0.0.0/0
#    
#    NOTE: The module hardcodes 0.0.0.0/0 for ALB ingress. To restrict access:
#    - Use AWS WAF with IP-based rules
#    - Or modify the security group post-deployment via AWS CLI/Console
#    - The alb_allowed_cidr_blocks variable is defined for documentation only
#
# 2. ECS Tasks Security Group (aws_security_group.tasks)
#    ├── Ingress: All ports from ALB security group only
#    ├── Ingress: Metrics port from gateway_metrics_scrape_cidrs (if metrics enabled)
#    └── Egress: All traffic to 0.0.0.0/0 (for LLM providers, RDS, Redis)
#
# 3. RDS Security Group (aws_security_group.rds) - Created when create_database=true
#    └── Ingress: Port 5432 from ECS tasks security group ONLY
#    
#    This follows least-privilege: only ECS tasks can reach the database.
#
# 4. Redis Security Group (aws_security_group.redis) - Created when create_redis=true
#    └── Ingress: Port 6379 from ECS tasks security group ONLY
#    
#    This follows least-privilege: only ECS tasks can reach Redis.
#
# ============================================================================
# ADDITIONAL SECURITY GROUPS (Created by this configuration)
# ============================================================================
#
# 5. Bastion Security Group (bastion.tf) - Created when bastion_enabled=true
#    ├── Ingress: Port 3389 (RDP) from bastion_allowed_rdp_cidr_blocks only
#    ├── Egress: Port 5432 to VPC CIDR (for Aurora access)
#    ├── Egress: Port 6379 to VPC CIDR (for Redis access)
#    └── Egress: Port 443 to 0.0.0.0/0 (for AWS CLI, updates)
#
# ============================================================================
# SECURITY GROUP TRAFFIC FLOW DIAGRAM
# ============================================================================
#
#   Internet
#      │
#      ▼
#  ┌────────────────────────────────────────────────────┐
#  │  ALB Security Group                                │
#  │  Ingress: 80, 443 from 0.0.0.0/0 (see note above) │
#  └────────────────────────────────────────────────────┘
#      │
#      │ Port 4000 (Gateway), 4001 (Backend), 3000 (UI)
#      ▼
#  ┌────────────────────────────────────────────────────┐
#  │  ECS Tasks Security Group                          │
#  │  Ingress: From ALB SG only                         │
#  └────────────────────────────────────────────────────┘
#      │                    │
#      │ Port 5432          │ Port 6379
#      ▼                    ▼
#  ┌──────────────┐    ┌──────────────┐
#  │  RDS SG      │    │  Redis SG    │
#  │  From ECS    │    │  From ECS    │
#  │  only        │    │  only        │
#  └──────────────┘    └──────────────┘
#
#  Admin Access (Optional, when bastion_enabled=true):
#
#   Admin Workstation
#      │
#      │ Port 3389 (RDP)
#      ▼
#  ┌────────────────────────────────────────────────────┐
#  │  Bastion Security Group                            │
#  │  Ingress: 3389 from bastion_allowed_rdp_cidr_blocks│
#  └────────────────────────────────────────────────────┘
#      │                    │
#      │ Port 5432          │ Port 6379
#      ▼                    ▼
#  ┌──────────────┐    ┌──────────────┐
#  │  Aurora      │    │  Redis       │
#  │  (via VPC)   │    │  (via VPC)   │
#  └──────────────┘    └──────────────┘
#
# ============================================================================
# VERIFICATION COMMANDS
# ============================================================================
#
# To verify security group configurations after deployment:
#
# 1. List all security groups for this deployment:
#    aws ec2 describe-security-groups \
#      --filters "Name=tag:litellm:stack,Values=${var.tenant}-litellm-${var.environment}" \
#      --query 'SecurityGroups[*].[GroupId,GroupName,Description]' \
#      --output table
#
# 2. Check ALB security group rules:
#    aws ec2 describe-security-groups \
#      --filters "Name=group-name,Values=*-alb" \
#      --query 'SecurityGroups[*].IpPermissions' \
#      --output json
#
# 3. Verify RDS security group only allows ECS:
#    aws ec2 describe-security-groups \
#      --filters "Name=group-name,Values=*-rds" \
#      --query 'SecurityGroups[*].IpPermissions' \
#      --output json
#
# ============================================================================

# This file contains only documentation comments. All actual security group
# resources are created by:
# - BerriAI/litellm/aws module (ALB, ECS, RDS, Redis security groups)
# - bastion.tf (Bastion security group when bastion_enabled=true)
