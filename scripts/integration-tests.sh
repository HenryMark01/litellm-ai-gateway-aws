#!/bin/bash
# ============================================================================
# LiteLLM AWS Infrastructure Integration Tests
# ============================================================================
# Post-deployment verification script for LiteLLM infrastructure on AWS.
# This script uses AWS CLI to verify the deployed infrastructure state
# without requiring direct connectivity from the local machine.
#
# ============================================================================

set -euo pipefail

# ============================================================================
# Configuration and Defaults
# ============================================================================

# Script defaults
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_REGION="us-east-1"

# Colors for output (disabled if not a terminal)
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[0;33m'
    readonly BLUE='\033[0;34m'
    readonly NC='\033[0m' # No Color
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly NC=''
fi

# Counters for test results
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
VERBOSE=false

# ============================================================================
# Utility Functions
# ============================================================================

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} -e <environment> -t <tenant> [OPTIONS]

Post-deployment integration tests for LiteLLM AWS infrastructure.
Verifies VPC, ALB, ECS, RDS, Redis, and Secrets Manager resources.

Required:
  -e, --environment    Environment name (e.g., staging, production)
  -t, --tenant         Tenant identifier used in resource naming

Options:
  -r, --region         AWS region (default: ${DEFAULT_REGION})
  -v, --verbose        Enable verbose output for debugging
  -h, --help           Show this help message

Examples:
  ${SCRIPT_NAME} -e staging -t mycompany
  ${SCRIPT_NAME} -e production -t mycompany -r us-west-2 -v

Exit Codes:
  0 - All tests passed
  1 - One or more tests failed
  2 - Script error (invalid arguments, missing dependencies)
EOF
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $*"
}

log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $*"
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*"
    fi
}

# Run a test and track results
# Usage: run_test "Test Name" command_to_run
run_test() {
    local test_name="$1"
    shift
    local result

    log_verbose "Running: $*"
    
    if result=$("$@" 2>&1); then
        log_success "$test_name"
        ((TESTS_PASSED++))
        if [[ "$VERBOSE" == "true" && -n "$result" ]]; then
            echo "         $result" | head -5
        fi
        return 0
    else
        log_fail "$test_name"
        echo "         Error: $result" | head -5
        ((TESTS_FAILED++))
        return 1
    fi
}

# Check if a command exists
require_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' not found. Please install it." >&2
        exit 2
    fi
}

# ============================================================================
# Parse Command Line Arguments
# ============================================================================

parse_args() {
    local environment=""
    local tenant=""
    local region="${DEFAULT_REGION}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e|--environment)
                environment="$2"
                shift 2
                ;;
            -t|--tenant)
                tenant="$2"
                shift 2
                ;;
            -r|--region)
                region="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                usage
                exit 2
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$environment" ]]; then
        echo "Error: Environment (-e) is required" >&2
        usage
        exit 2
    fi

    if [[ -z "$tenant" ]]; then
        echo "Error: Tenant (-t) is required" >&2
        usage
        exit 2
    fi

    # Export for use in tests
    export ENVIRONMENT="$environment"
    export TENANT="$tenant"
    export AWS_REGION="$region"
    export AWS_DEFAULT_REGION="$region"
}

# ============================================================================
# VPC and Subnet Tests
# ============================================================================

test_vpc_configuration() {
    log_info "Testing VPC and Subnet Configuration..."
    
    local vpc_name="${TENANT}-litellm-${ENVIRONMENT}"
    local vpc_id
    
    # Find VPC by name tag
    vpc_id=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=*${vpc_name}*" \
        --query 'Vpcs[0].VpcId' \
        --output text 2>/dev/null || echo "None")
    
    if [[ "$vpc_id" == "None" || -z "$vpc_id" ]]; then
        log_fail "VPC exists with name containing '${vpc_name}'"
        ((TESTS_FAILED++))
        return 1
    fi
    
    log_success "VPC exists: ${vpc_id}"
    ((TESTS_PASSED++))
    
    # Verify VPC is available
    run_test "VPC state is 'available'" \
        bash -c "aws ec2 describe-vpcs --vpc-ids ${vpc_id} --query 'Vpcs[0].State' --output text | grep -q 'available'"
    
    # Get and verify VPC CIDR
    local vpc_cidr
    vpc_cidr=$(aws ec2 describe-vpcs --vpc-ids "$vpc_id" --query 'Vpcs[0].CidrBlock' --output text)
    log_verbose "VPC CIDR: ${vpc_cidr}"
    
    # Check for subnets
    local subnet_count
    subnet_count=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query 'length(Subnets)' \
        --output text)
    
    run_test "VPC has subnets (found: ${subnet_count})" \
        bash -c "[[ ${subnet_count} -ge 2 ]]"
    
    # Check for public subnets (with route to Internet Gateway)
    local public_subnets
    public_subnets=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=*public*" \
        --query 'Subnets[*].SubnetId' \
        --output text | wc -w)
    
    run_test "Public subnets exist (found: ${public_subnets})" \
        bash -c "[[ ${public_subnets} -ge 1 ]]"
    
    # Check for private subnets
    local private_subnets
    private_subnets=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=*private*" \
        --query 'Subnets[*].SubnetId' \
        --output text | wc -w)
    
    run_test "Private subnets exist (found: ${private_subnets})" \
        bash -c "[[ ${private_subnets} -ge 1 ]]"
    
    # Check for Internet Gateway
    local igw_count
    igw_count=$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
        --query 'length(InternetGateways)' \
        --output text)
    
    run_test "Internet Gateway attached to VPC" \
        bash -c "[[ ${igw_count} -ge 1 ]]"
    
    # Check for NAT Gateway
    local nat_count
    nat_count=$(aws ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=${vpc_id}" "Name=state,Values=available" \
        --query 'length(NatGateways)' \
        --output text)
    
    run_test "NAT Gateway exists and is available (found: ${nat_count})" \
        bash -c "[[ ${nat_count} -ge 1 ]]"
    
    export VPC_ID="$vpc_id"
}

# ============================================================================
# Application Load Balancer Tests
# ============================================================================

test_alb_configuration() {
    log_info "Testing Application Load Balancer Configuration..."
    
    local alb_name="${TENANT}-litellm-${ENVIRONMENT}"
    local alb_arn
    
    # Find ALB by name
    alb_arn=$(aws elbv2 describe-load-balancers \
        --query "LoadBalancers[?contains(LoadBalancerName, '${alb_name}')].LoadBalancerArn" \
        --output text 2>/dev/null | head -1)
    
    if [[ -z "$alb_arn" ]]; then
        log_fail "ALB exists with name containing '${alb_name}'"
        ((TESTS_FAILED++))
        return 1
    fi
    
    log_success "ALB exists: ${alb_arn}"
    ((TESTS_PASSED++))
    
    # Verify ALB is active
    local alb_state
    alb_state=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns "$alb_arn" \
        --query 'LoadBalancers[0].State.Code' \
        --output text)
    
    run_test "ALB state is 'active' (current: ${alb_state})" \
        bash -c "[[ '${alb_state}' == 'active' ]]"
    
    # Get ALB DNS name
    local alb_dns
    alb_dns=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns "$alb_arn" \
        --query 'LoadBalancers[0].DNSName' \
        --output text)
    log_verbose "ALB DNS: ${alb_dns}"
    
    # Check listeners
    local listener_count
    listener_count=$(aws elbv2 describe-listeners \
        --load-balancer-arn "$alb_arn" \
        --query 'length(Listeners)' \
        --output text)
    
    run_test "ALB has listeners configured (found: ${listener_count})" \
        bash -c "[[ ${listener_count} -ge 1 ]]"
    
    # Check target groups
    local target_groups
    target_groups=$(aws elbv2 describe-target-groups \
        --load-balancer-arn "$alb_arn" \
        --query 'TargetGroups[*].TargetGroupName' \
        --output text)
    
    local tg_count
    tg_count=$(echo "$target_groups" | wc -w)
    run_test "ALB has target groups (found: ${tg_count})" \
        bash -c "[[ ${tg_count} -ge 1 ]]"
    
    # Check target health for each target group
    for tg_arn in $(aws elbv2 describe-target-groups \
        --load-balancer-arn "$alb_arn" \
        --query 'TargetGroups[*].TargetGroupArn' \
        --output text); do
        
        local tg_name
        tg_name=$(aws elbv2 describe-target-groups \
            --target-group-arns "$tg_arn" \
            --query 'TargetGroups[0].TargetGroupName' \
            --output text)
        
        local healthy_count
        healthy_count=$(aws elbv2 describe-target-health \
            --target-group-arn "$tg_arn" \
            --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`]' \
            --output json | jq 'length')
        
        local total_count
        total_count=$(aws elbv2 describe-target-health \
            --target-group-arn "$tg_arn" \
            --query 'length(TargetHealthDescriptions)' \
            --output text)
        
        if [[ "$total_count" -eq 0 ]]; then
            log_skip "Target group '${tg_name}' has no targets registered"
            ((TESTS_SKIPPED++))
        elif [[ "$healthy_count" -ge 1 ]]; then
            log_success "Target group '${tg_name}' has healthy targets (${healthy_count}/${total_count})"
            ((TESTS_PASSED++))
        else
            log_fail "Target group '${tg_name}' has no healthy targets (${healthy_count}/${total_count})"
            ((TESTS_FAILED++))
        fi
    done
    
    export ALB_ARN="$alb_arn"
    export ALB_DNS="$alb_dns"
}

# ============================================================================
# ECS Service Tests
# ============================================================================

test_ecs_services() {
    log_info "Testing ECS Cluster and Services..."
    
    local cluster_name="${TENANT}-litellm-${ENVIRONMENT}"
    local cluster_arn
    
    # Find ECS cluster
    cluster_arn=$(aws ecs describe-clusters \
        --clusters "$cluster_name" \
        --query 'clusters[0].clusterArn' \
        --output text 2>/dev/null || echo "None")
    
    if [[ "$cluster_arn" == "None" || -z "$cluster_arn" ]]; then
        log_fail "ECS cluster exists: ${cluster_name}"
        ((TESTS_FAILED++))
        return 1
    fi
    
    log_success "ECS cluster exists: ${cluster_name}"
    ((TESTS_PASSED++))
    
    # Verify cluster is active
    local cluster_status
    cluster_status=$(aws ecs describe-clusters \
        --clusters "$cluster_name" \
        --query 'clusters[0].status' \
        --output text)
    
    run_test "ECS cluster status is 'ACTIVE' (current: ${cluster_status})" \
        bash -c "[[ '${cluster_status}' == 'ACTIVE' ]]"
    
    # Check registered container instances count (for Fargate, this is 0)
    local registered_instances
    registered_instances=$(aws ecs describe-clusters \
        --clusters "$cluster_name" \
        --query 'clusters[0].registeredContainerInstancesCount' \
        --output text)
    log_verbose "Registered container instances: ${registered_instances} (expected 0 for Fargate)"
    
    # Test each expected service
    local services=("gateway" "backend" "ui")
    
    for service_type in "${services[@]}"; do
        local service_name="${TENANT}-litellm-${ENVIRONMENT}-${service_type}"
        
        local service_status
        service_status=$(aws ecs describe-services \
            --cluster "$cluster_name" \
            --services "$service_name" \
            --query 'services[0].status' \
            --output text 2>/dev/null || echo "MISSING")
        
        if [[ "$service_status" == "MISSING" || "$service_status" == "None" ]]; then
            log_skip "ECS service '${service_name}' not found (may not be deployed)"
            ((TESTS_SKIPPED++))
            continue
        fi
        
        run_test "ECS service '${service_name}' status is 'ACTIVE'" \
            bash -c "[[ '${service_status}' == 'ACTIVE' ]]"
        
        # Check running task count
        local running_count desired_count
        running_count=$(aws ecs describe-services \
            --cluster "$cluster_name" \
            --services "$service_name" \
            --query 'services[0].runningCount' \
            --output text)
        
        desired_count=$(aws ecs describe-services \
            --cluster "$cluster_name" \
            --services "$service_name" \
            --query 'services[0].desiredCount' \
            --output text)
        
        if [[ "$running_count" -eq "$desired_count" && "$desired_count" -gt 0 ]]; then
            log_success "ECS service '${service_name}' running tasks match desired (${running_count}/${desired_count})"
            ((TESTS_PASSED++))
        elif [[ "$desired_count" -eq 0 ]]; then
            log_skip "ECS service '${service_name}' has desired count of 0"
            ((TESTS_SKIPPED++))
        else
            log_fail "ECS service '${service_name}' running tasks mismatch (${running_count}/${desired_count})"
            ((TESTS_FAILED++))
        fi
    done
    
    export CLUSTER_NAME="$cluster_name"
}

# ============================================================================
# Database Tests
# ============================================================================

test_database_configuration() {
    log_info "Testing Aurora PostgreSQL Configuration..."
    
    local db_cluster_id="${TENANT}-litellm-${ENVIRONMENT}"
    local cluster_status
    
    # Find Aurora cluster
    cluster_status=$(aws rds describe-db-clusters \
        --db-cluster-identifier "$db_cluster_id" \
        --query 'DBClusters[0].Status' \
        --output text 2>/dev/null || echo "not-found")
    
    if [[ "$cluster_status" == "not-found" ]]; then
        log_skip "Aurora cluster '${db_cluster_id}' not found (may use existing database)"
        ((TESTS_SKIPPED++))
        return 0
    fi
    
    run_test "Aurora cluster '${db_cluster_id}' is available (status: ${cluster_status})" \
        bash -c "[[ '${cluster_status}' == 'available' ]]"
    
    # Check encryption at rest
    local storage_encrypted
    storage_encrypted=$(aws rds describe-db-clusters \
        --db-cluster-identifier "$db_cluster_id" \
        --query 'DBClusters[0].StorageEncrypted' \
        --output text)
    
    run_test "Aurora cluster has encryption at rest enabled" \
        bash -c "[[ '${storage_encrypted}' == 'True' ]]"
    
    # Check IAM authentication
    local iam_auth
    iam_auth=$(aws rds describe-db-clusters \
        --db-cluster-identifier "$db_cluster_id" \
        --query 'DBClusters[0].IAMDatabaseAuthenticationEnabled' \
        --output text)
    
    run_test "Aurora cluster has IAM authentication enabled" \
        bash -c "[[ '${iam_auth}' == 'True' ]]"
    
    # Check backup retention
    local backup_retention
    backup_retention=$(aws rds describe-db-clusters \
        --db-cluster-identifier "$db_cluster_id" \
        --query 'DBClusters[0].BackupRetentionPeriod' \
        --output text)
    
    run_test "Aurora backup retention >= 7 days (current: ${backup_retention})" \
        bash -c "[[ ${backup_retention} -ge 7 ]]"
    
    # Check cluster members (instances)
    local member_count
    member_count=$(aws rds describe-db-clusters \
        --db-cluster-identifier "$db_cluster_id" \
        --query 'length(DBClusters[0].DBClusterMembers)' \
        --output text)
    
    run_test "Aurora cluster has instances (found: ${member_count})" \
        bash -c "[[ ${member_count} -ge 1 ]]"
    
    # Check instance status
    for instance_id in $(aws rds describe-db-clusters \
        --db-cluster-identifier "$db_cluster_id" \
        --query 'DBClusters[0].DBClusterMembers[*].DBInstanceIdentifier' \
        --output text); do
        
        local instance_status
        instance_status=$(aws rds describe-db-instances \
            --db-instance-identifier "$instance_id" \
            --query 'DBInstances[0].DBInstanceStatus' \
            --output text)
        
        run_test "Aurora instance '${instance_id}' is available (status: ${instance_status})" \
            bash -c "[[ '${instance_status}' == 'available' ]]"
    done
}

# ============================================================================
# Redis Tests
# ============================================================================

test_redis_configuration() {
    log_info "Testing ElastiCache Redis Configuration..."
    
    local redis_cluster_id="${TENANT}-litellm-${ENVIRONMENT}"
    local replication_group_id="${redis_cluster_id}"
    
    # Try to find replication group first (more common for production)
    local rg_status
    rg_status=$(aws elasticache describe-replication-groups \
        --replication-group-id "$replication_group_id" \
        --query 'ReplicationGroups[0].Status' \
        --output text 2>/dev/null || echo "not-found")
    
    if [[ "$rg_status" == "not-found" ]]; then
        # Try cluster mode
        local cluster_status
        cluster_status=$(aws elasticache describe-cache-clusters \
            --cache-cluster-id "$redis_cluster_id" \
            --query 'CacheClusters[0].CacheClusterStatus' \
            --output text 2>/dev/null || echo "not-found")
        
        if [[ "$cluster_status" == "not-found" ]]; then
            log_skip "Redis cluster '${redis_cluster_id}' not found (may use existing cache)"
            ((TESTS_SKIPPED++))
            return 0
        fi
        
        run_test "Redis cluster '${redis_cluster_id}' is available (status: ${cluster_status})" \
            bash -c "[[ '${cluster_status}' == 'available' ]]"
        
        # Check encryption
        local at_rest_encrypted transit_encrypted
        at_rest_encrypted=$(aws elasticache describe-cache-clusters \
            --cache-cluster-id "$redis_cluster_id" \
            --query 'CacheClusters[0].AtRestEncryptionEnabled' \
            --output text 2>/dev/null || echo "False")
        
        transit_encrypted=$(aws elasticache describe-cache-clusters \
            --cache-cluster-id "$redis_cluster_id" \
            --query 'CacheClusters[0].TransitEncryptionEnabled' \
            --output text 2>/dev/null || echo "False")
        
        run_test "Redis cluster has encryption at rest enabled" \
            bash -c "[[ '${at_rest_encrypted}' == 'True' ]]"
        
        run_test "Redis cluster has encryption in transit (TLS) enabled" \
            bash -c "[[ '${transit_encrypted}' == 'True' ]]"
    else
        run_test "Redis replication group '${replication_group_id}' is available (status: ${rg_status})" \
            bash -c "[[ '${rg_status}' == 'available' ]]"
        
        # Check encryption for replication group
        local at_rest_encrypted transit_encrypted
        at_rest_encrypted=$(aws elasticache describe-replication-groups \
            --replication-group-id "$replication_group_id" \
            --query 'ReplicationGroups[0].AtRestEncryptionEnabled' \
            --output text)
        
        transit_encrypted=$(aws elasticache describe-replication-groups \
            --replication-group-id "$replication_group_id" \
            --query 'ReplicationGroups[0].TransitEncryptionEnabled' \
            --output text)
        
        run_test "Redis replication group has encryption at rest enabled" \
            bash -c "[[ '${at_rest_encrypted}' == 'True' ]]"
        
        run_test "Redis replication group has encryption in transit (TLS) enabled" \
            bash -c "[[ '${transit_encrypted}' == 'True' ]]"
        
        # Check node groups
        local node_count
        node_count=$(aws elasticache describe-replication-groups \
            --replication-group-id "$replication_group_id" \
            --query 'length(ReplicationGroups[0].NodeGroups[0].NodeGroupMembers)' \
            --output text)
        
        run_test "Redis has node group members (found: ${node_count})" \
            bash -c "[[ ${node_count} -ge 1 ]]"
    fi
}

# ============================================================================
# Secrets Manager Tests
# ============================================================================

test_secrets_configuration() {
    log_info "Testing Secrets Manager Configuration..."
    
    local secret_prefix="/${TENANT}/${ENVIRONMENT}/litellm"
    
    # List of expected secrets
    local expected_secrets=(
        "master-key"
        "openai-api-key"
        "anthropic-api-key"
    )
    
    for secret_name in "${expected_secrets[@]}"; do
        local full_secret_name="${secret_prefix}/${secret_name}"
        local secret_arn
        
        # Try to find the secret
        secret_arn=$(aws secretsmanager describe-secret \
            --secret-id "$full_secret_name" \
            --query 'ARN' \
            --output text 2>/dev/null || echo "not-found")
        
        if [[ "$secret_arn" == "not-found" ]]; then
            # Try alternate naming convention (module may use different path)
            local alt_secret_name="${TENANT}-litellm-${ENVIRONMENT}-${secret_name}"
            secret_arn=$(aws secretsmanager describe-secret \
                --secret-id "$alt_secret_name" \
                --query 'ARN' \
                --output text 2>/dev/null || echo "not-found")
        fi
        
        if [[ "$secret_arn" == "not-found" ]]; then
            log_skip "Secret '${secret_name}' not found at expected paths"
            ((TESTS_SKIPPED++))
            continue
        fi
        
        log_success "Secret '${secret_name}' exists"
        ((TESTS_PASSED++))
        
        # Check if secret has a current version
        local version_count
        version_count=$(aws secretsmanager list-secret-version-ids \
            --secret-id "$secret_arn" \
            --query 'length(Versions)' \
            --output text 2>/dev/null || echo "0")
        
        if [[ "$version_count" -ge 1 ]]; then
            log_success "Secret '${secret_name}' has version(s) (${version_count})"
            ((TESTS_PASSED++))
        else
            log_fail "Secret '${secret_name}' has no versions"
            ((TESTS_FAILED++))
        fi
    done
    
    # Also check for database master password secret
    local db_password_secret="${TENANT}-litellm-${ENVIRONMENT}-db-master-password"
    local db_secret_arn
    db_secret_arn=$(aws secretsmanager describe-secret \
        --secret-id "$db_password_secret" \
        --query 'ARN' \
        --output text 2>/dev/null || echo "not-found")
    
    if [[ "$db_secret_arn" != "not-found" ]]; then
        log_success "Database master password secret exists"
        ((TESTS_PASSED++))
    else
        log_verbose "Database master password secret not found at '${db_password_secret}'"
    fi
}

# ============================================================================
# S3 Configuration Bucket Tests
# ============================================================================

test_s3_configuration() {
    log_info "Testing S3 Configuration Bucket..."
    
    local bucket_name="${TENANT}-litellm-${ENVIRONMENT}"
    
    # Try to find the bucket
    local bucket_exists
    bucket_exists=$(aws s3api head-bucket --bucket "$bucket_name" 2>&1 && echo "true" || echo "false")
    
    if [[ "$bucket_exists" != "true" ]]; then
        # Try alternate naming
        bucket_name="${TENANT}-${ENVIRONMENT}-litellm-config"
        bucket_exists=$(aws s3api head-bucket --bucket "$bucket_name" 2>&1 && echo "true" || echo "false")
    fi
    
    if [[ "$bucket_exists" != "true" ]]; then
        log_skip "S3 config bucket not found at expected locations"
        ((TESTS_SKIPPED++))
        return 0
    fi
    
    log_success "S3 bucket '${bucket_name}' exists"
    ((TESTS_PASSED++))
    
    # Check versioning
    local versioning_status
    versioning_status=$(aws s3api get-bucket-versioning \
        --bucket "$bucket_name" \
        --query 'Status' \
        --output text 2>/dev/null || echo "Disabled")
    
    run_test "S3 bucket has versioning enabled (status: ${versioning_status})" \
        bash -c "[[ '${versioning_status}' == 'Enabled' ]]"
    
    # Check encryption
    local encryption_algorithm
    encryption_algorithm=$(aws s3api get-bucket-encryption \
        --bucket "$bucket_name" \
        --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
        --output text 2>/dev/null || echo "none")
    
    run_test "S3 bucket has encryption enabled (algorithm: ${encryption_algorithm})" \
        bash -c "[[ '${encryption_algorithm}' == 'AES256' || '${encryption_algorithm}' == 'aws:kms' ]]"
    
    # Check public access block
    local public_access_blocked
    public_access_blocked=$(aws s3api get-public-access-block \
        --bucket "$bucket_name" \
        --query 'PublicAccessBlockConfiguration.BlockPublicAcls' \
        --output text 2>/dev/null || echo "false")
    
    run_test "S3 bucket has public access blocked" \
        bash -c "[[ '${public_access_blocked}' == 'True' ]]"
    
    # Check for config.yaml (may or may not exist yet)
    local config_exists
    config_exists=$(aws s3api head-object \
        --bucket "$bucket_name" \
        --key "config.yaml" 2>&1 && echo "true" || echo "false")
    
    if [[ "$config_exists" == "true" ]]; then
        log_success "config.yaml exists in S3 bucket"
        ((TESTS_PASSED++))
    else
        log_skip "config.yaml not found in S3 bucket (may not be uploaded yet)"
        ((TESTS_SKIPPED++))
    fi
}

# ============================================================================
# CloudWatch Logs Tests
# ============================================================================

test_cloudwatch_logs() {
    log_info "Testing CloudWatch Log Groups..."
    
    local log_group_prefix="/ecs/${TENANT}-litellm-${ENVIRONMENT}"
    
    # List log groups with the prefix
    local log_groups
    log_groups=$(aws logs describe-log-groups \
        --log-group-name-prefix "$log_group_prefix" \
        --query 'logGroups[*].logGroupName' \
        --output text 2>/dev/null || echo "")
    
    if [[ -z "$log_groups" ]]; then
        log_skip "No CloudWatch log groups found with prefix '${log_group_prefix}'"
        ((TESTS_SKIPPED++))
        return 0
    fi
    
    local log_group_count
    log_group_count=$(echo "$log_groups" | wc -w)
    log_success "CloudWatch log groups exist (found: ${log_group_count})"
    ((TESTS_PASSED++))
    
    # Check retention for each log group
    for lg in $log_groups; do
        local retention
        retention=$(aws logs describe-log-groups \
            --log-group-name-prefix "$lg" \
            --query 'logGroups[0].retentionInDays' \
            --output text)
        
        if [[ "$retention" == "None" || -z "$retention" ]]; then
            log_verbose "Log group '${lg}' has no retention policy (unlimited)"
        else
            log_verbose "Log group '${lg}' retention: ${retention} days"
        fi
    done
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    # Handle help flag early (before dependency checks)
    for arg in "$@"; do
        if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
            usage
            exit 0
        fi
    done
    
    # Check dependencies
    require_command aws
    require_command jq
    
    # Parse arguments
    parse_args "$@"
    
    echo ""
    echo "============================================================"
    echo "LiteLLM AWS Infrastructure Integration Tests"
    echo "============================================================"
    echo "Environment: ${ENVIRONMENT}"
    echo "Tenant:      ${TENANT}"
    echo "Region:      ${AWS_REGION}"
    echo "Verbose:     ${VERBOSE}"
    echo "============================================================"
    echo ""
    
    # Verify AWS credentials
    log_info "Verifying AWS credentials..."
    if ! aws sts get-caller-identity &>/dev/null; then
        echo "Error: AWS credentials not configured or invalid" >&2
        exit 2
    fi
    log_success "AWS credentials verified"
    ((TESTS_PASSED++))
    echo ""
    
    # Run all test suites
    test_vpc_configuration
    echo ""
    
    test_alb_configuration
    echo ""
    
    test_ecs_services
    echo ""
    
    test_database_configuration
    echo ""
    
    test_redis_configuration
    echo ""
    
    test_secrets_configuration
    echo ""
    
    test_s3_configuration
    echo ""
    
    test_cloudwatch_logs
    echo ""
    
    # Print summary
    echo "============================================================"
    echo "Test Results Summary"
    echo "============================================================"
    echo -e "${GREEN}Passed:${NC}  ${TESTS_PASSED}"
    echo -e "${RED}Failed:${NC}  ${TESTS_FAILED}"
    echo -e "${YELLOW}Skipped:${NC} ${TESTS_SKIPPED}"
    echo "============================================================"
    
    # Exit with appropriate code
    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        echo ""
        log_fail "Integration tests completed with ${TESTS_FAILED} failure(s)"
        exit 1
    else
        echo ""
        log_success "All integration tests passed!"
        exit 0
    fi
}

# Run main function
main "$@"
