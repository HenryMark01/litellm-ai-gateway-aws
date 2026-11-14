#!/usr/bin/env bash
#
# plan-verify.sh - Terraform Plan Verification Script
#
# This script analyzes Terraform plan output for:
# - Unexpected resource deletions
# - Resource counts by type (creates/updates/deletes)
# - Security group rule verification (overly permissive rules)
#
#
# Usage: ./scripts/plan-verify.sh <environment> [terraform_dir]
#   environment  - Environment name (e.g., staging, production)
#   terraform_dir - Optional path to terraform directory (default: terraform/main)
#
# Exit codes:
#   0 - All checks passed
#   1 - Errors found (deletions, security issues)
#   2 - Script error (missing dependencies, invalid input)

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PLAN_FILE="tfplan"
PLAN_JSON_FILE="tfplan.json"

#######################################
# Print colored output
# Arguments:
#   $1 - Color code
#   $2 - Message
#######################################
print_color() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

#######################################
# Print section header
# Arguments:
#   $1 - Header text
#######################################
print_header() {
    echo ""
    print_color "$BLUE" "═══════════════════════════════════════════════════════════════"
    print_color "$BLUE" "$1"
    print_color "$BLUE" "═══════════════════════════════════════════════════════════════"
}

#######################################
# Print usage information
#######################################
usage() {
    echo "Usage: $0 <environment> [terraform_dir]"
    echo ""
    echo "Arguments:"
    echo "  environment    Environment name (e.g., staging, production)"
    echo "  terraform_dir  Optional path to terraform directory (default: terraform/main)"
    echo ""
    echo "Examples:"
    echo "  $0 staging"
    echo "  $0 production terraform/main"
    exit 2
}

#######################################
# Check required dependencies
#######################################
check_dependencies() {
    local missing_deps=()
    
    if ! command -v terraform &> /dev/null; then
        missing_deps+=("terraform")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_color "$RED" "ERROR: Missing required dependencies: ${missing_deps[*]}"
        print_color "$YELLOW" "Please install the missing tools and try again."
        exit 2
    fi
}

#######################################
# Generate Terraform plan in JSON format
# Arguments:
#   $1 - Terraform directory
#   $2 - Environment name
#######################################
generate_plan() {
    local tf_dir="$1"
    local environment="$2"
    local tfvars_file="${PROJECT_ROOT}/terraform/environments/${environment}.tfvars"
    
    print_header "Generating Terraform Plan"
    
    cd "$tf_dir"
    
    # Check if tfvars file exists
    if [[ -f "$tfvars_file" ]]; then
        print_color "$GREEN" "Using tfvars file: $tfvars_file"
        terraform plan -var-file="$tfvars_file" -out="$PLAN_FILE" -input=false
    else
        print_color "$YELLOW" "WARNING: tfvars file not found: $tfvars_file"
        print_color "$YELLOW" "Generating plan without environment-specific variables..."
        terraform plan -out="$PLAN_FILE" -input=false
    fi
    
    # Convert plan to JSON format
    print_color "$GREEN" "Converting plan to JSON format..."
    terraform show -json "$PLAN_FILE" > "$PLAN_JSON_FILE"
    
    if [[ ! -f "$PLAN_JSON_FILE" ]]; then
        print_color "$RED" "ERROR: Failed to generate plan JSON file"
        exit 2
    fi
    
    print_color "$GREEN" "Plan generated successfully: $PLAN_JSON_FILE"
}

#######################################
# Check for unexpected resource deletions
# Arguments:
#   $1 - Path to plan JSON file
# Returns:
#   0 if no deletions, 1 if deletions found
#######################################
check_deletions() {
    local plan_json="$1"
    local deletion_count=0
    local has_critical_deletions=false
    
    print_header "Checking for Resource Deletions"
    
    # Extract resources with delete or replace actions
    local deletions
    deletions=$(jq -r '
        .resource_changes[]? | 
        select(.change.actions | contains(["delete"]) or contains(["replace"])) |
        "\(.type) | \(.name) | \(.change.actions | join(", "))"
    ' "$plan_json" 2>/dev/null || echo "")
    
    if [[ -z "$deletions" ]]; then
        print_color "$GREEN" "✓ No resource deletions detected"
        return 0
    fi
    
    print_color "$YELLOW" "⚠ Resources scheduled for deletion or replacement:"
    echo ""
    
    # Critical resource types that should be reviewed carefully
    local critical_types=(
        "aws_db_instance"
        "aws_rds_cluster"
        "aws_rds_cluster_instance"
        "aws_s3_bucket"
        "aws_elasticache_cluster"
        "aws_elasticache_replication_group"
        "aws_secretsmanager_secret"
        "aws_kms_key"
        "aws_vpc"
        "aws_ecs_cluster"
    )
    
    while IFS='|' read -r type name actions; do
        type=$(echo "$type" | xargs)
        name=$(echo "$name" | xargs)
        actions=$(echo "$actions" | xargs)
        
        ((deletion_count++))
        
        # Check if this is a critical resource type
        local is_critical=false
        for critical_type in "${critical_types[@]}"; do
            if [[ "$type" == "$critical_type" ]]; then
                is_critical=true
                has_critical_deletions=true
                break
            fi
        done
        
        if [[ "$is_critical" == true ]]; then
            print_color "$RED" "  ✗ CRITICAL: $type.$name (actions: $actions)"
        else
            print_color "$YELLOW" "  ⚠ $type.$name (actions: $actions)"
        fi
    done <<< "$deletions"
    
    echo ""
    print_color "$YELLOW" "Total deletions/replacements: $deletion_count"
    
    if [[ "$has_critical_deletions" == true ]]; then
        print_color "$RED" "⚠ CRITICAL: Plan includes deletion of stateful resources!"
        print_color "$RED" "   Review carefully before applying."
        return 1
    fi
    
    return 0
}

#######################################
# Verify resource counts by type
# Arguments:
#   $1 - Path to plan JSON file
#######################################
verify_resource_counts() {
    local plan_json="$1"
    
    print_header "Resource Change Summary"
    
    # Count resources by action type
    local creates updates deletes no_ops
    creates=$(jq '[.resource_changes[]? | select(.change.actions | contains(["create"]))] | length' "$plan_json" 2>/dev/null || echo "0")
    updates=$(jq '[.resource_changes[]? | select(.change.actions | contains(["update"]))] | length' "$plan_json" 2>/dev/null || echo "0")
    deletes=$(jq '[.resource_changes[]? | select(.change.actions | contains(["delete"]))] | length' "$plan_json" 2>/dev/null || echo "0")
    no_ops=$(jq '[.resource_changes[]? | select(.change.actions == ["no-op"])] | length' "$plan_json" 2>/dev/null || echo "0")
    
    echo ""
    print_color "$GREEN" "  + Create:  $creates"
    print_color "$YELLOW" "  ~ Update:  $updates"
    print_color "$RED" "  - Delete:  $deletes"
    echo "    No-op:   $no_ops"
    echo ""
    
    # Group by resource type
    print_color "$BLUE" "Changes by Resource Type:"
    echo ""
    
    jq -r '
        [.resource_changes[]? | select(.change.actions != ["no-op"])] |
        group_by(.type) |
        map({
            type: .[0].type,
            count: length,
            actions: [.[].change.actions[]] | unique | join(", ")
        }) |
        sort_by(.count) | reverse |
        .[] |
        "  \(.type): \(.count) (\(.actions))"
    ' "$plan_json" 2>/dev/null || echo "  No changes detected"
    
    echo ""
}

#######################################
# Check security group rules for overly permissive configurations
# Arguments:
#   $1 - Path to plan JSON file
# Returns:
#   0 if no issues, 1 if security issues found
#######################################
check_security_groups() {
    local plan_json="$1"
    local has_issues=false
    
    print_header "Security Group Rule Verification"
    
    # Check for overly permissive ingress rules (0.0.0.0/0)
    local permissive_rules
    permissive_rules=$(jq -r '
        .resource_changes[]? |
        select(.type == "aws_security_group" or .type == "aws_security_group_rule" or .type == "aws_vpc_security_group_ingress_rule") |
        select(.change.actions | contains(["create"]) or contains(["update"])) |
        .change.after //
        .change.after_unknown |
        .. | objects |
        select(.cidr_blocks? // .cidr_ipv4? | 
            if type == "array" then contains(["0.0.0.0/0"]) 
            elif type == "string" then . == "0.0.0.0/0"
            else false end
        ) |
        "\(.from_port // "all")-\(.to_port // "all")"
    ' "$plan_json" 2>/dev/null | sort -u || echo "")
    
    # Check for security group resources with ingress blocks
    local sg_ingress_rules
    sg_ingress_rules=$(jq -r '
        .resource_changes[]? |
        select(.type == "aws_security_group") |
        select(.change.actions | contains(["create"]) or contains(["update"])) |
        .change.after.ingress[]? |
        select(.cidr_blocks | if type == "array" then contains(["0.0.0.0/0"]) else false end) |
        "Port \(.from_port)-\(.to_port) Protocol: \(.protocol)"
    ' "$plan_json" 2>/dev/null | sort -u || echo "")
    
    if [[ -n "$permissive_rules" || -n "$sg_ingress_rules" ]]; then
        has_issues=true
        print_color "$YELLOW" "⚠ Security groups with 0.0.0.0/0 (open to internet) detected:"
        echo ""
        
        if [[ -n "$permissive_rules" ]]; then
            echo "$permissive_rules" | while read -r rule; do
                if [[ -n "$rule" ]]; then
                    print_color "$YELLOW" "  ⚠ Ports: $rule"
                fi
            done
        fi
        
        if [[ -n "$sg_ingress_rules" ]]; then
            echo "$sg_ingress_rules" | while read -r rule; do
                if [[ -n "$rule" ]]; then
                    print_color "$YELLOW" "  ⚠ $rule"
                fi
            done
        fi
        
        echo ""
        
        # Check if the open rules are for expected ports (80, 443 for ALB)
        local expected_open_ports=("80" "443")
        local unexpected_open_ports=false
        
        # Combine and check all rules
        local all_rules="${permissive_rules}${sg_ingress_rules}"
        while read -r rule; do
            if [[ -n "$rule" ]]; then
                # Extract port numbers
                if [[ "$rule" =~ ([0-9]+) ]]; then
                    local port="${BASH_REMATCH[1]}"
                    local is_expected=false
                    for expected in "${expected_open_ports[@]}"; do
                        if [[ "$port" == "$expected" ]]; then
                            is_expected=true
                            break
                        fi
                    done
                    if [[ "$is_expected" == false && "$port" != "all" ]]; then
                        unexpected_open_ports=true
                    fi
                fi
            fi
        done <<< "$all_rules"
        
        if [[ "$unexpected_open_ports" == true ]]; then
            print_color "$RED" "✗ FAIL: Unexpected ports open to 0.0.0.0/0"
            print_color "$YELLOW" "   Expected: Only ports 80 and 443 should be open to the internet (for ALB)"
            return 1
        else
            print_color "$GREEN" "✓ Open ports are expected (80/443 for ALB)"
        fi
    else
        print_color "$GREEN" "✓ No overly permissive security group rules detected"
    fi
    
    # Check for security groups allowing all traffic (protocol = -1)
    local all_traffic_rules
    all_traffic_rules=$(jq -r '
        .resource_changes[]? |
        select(.type == "aws_security_group" or .type == "aws_security_group_rule") |
        select(.change.actions | contains(["create"]) or contains(["update"])) |
        select(
            (.change.after.ingress[]?.protocol? == "-1") or
            (.change.after.protocol? == "-1" and .change.after.type? == "ingress")
        ) |
        .address
    ' "$plan_json" 2>/dev/null | sort -u || echo "")
    
    if [[ -n "$all_traffic_rules" ]]; then
        print_color "$YELLOW" "⚠ Security groups allowing all protocols detected:"
        echo "$all_traffic_rules" | while read -r rule; do
            if [[ -n "$rule" ]]; then
                print_color "$YELLOW" "  ⚠ $rule"
            fi
        done
        echo ""
    fi
    
    # Check egress rules - generally less concerning but worth noting
    local open_egress
    open_egress=$(jq -r '
        [.resource_changes[]? |
        select(.type == "aws_security_group") |
        select(.change.actions | contains(["create"]) or contains(["update"])) |
        select(.change.after.egress[]?.cidr_blocks | if type == "array" then contains(["0.0.0.0/0"]) else false end)] |
        length
    ' "$plan_json" 2>/dev/null || echo "0")
    
    if [[ "$open_egress" -gt 0 ]]; then
        print_color "$BLUE" "ℹ $open_egress security group(s) with open egress (0.0.0.0/0)"
        print_color "$BLUE" "  This is typically expected for outbound internet access."
    fi
    
    echo ""
    
    if [[ "$has_issues" == true ]]; then
        return 0  # Warnings but not failures for expected ALB ports
    fi
    
    return 0
}

#######################################
# Check for sensitive data exposure
# Arguments:
#   $1 - Path to plan JSON file
#######################################
check_sensitive_data() {
    local plan_json="$1"
    
    print_header "Sensitive Data Check"
    
    # Check for potentially exposed secrets in plan
    local exposed_secrets
    exposed_secrets=$(jq -r '
        .resource_changes[]? |
        select(.change.after | 
            (.. | strings | test("(?i)(password|secret|api.?key|token)"; "i")) // false
        ) |
        .address
    ' "$plan_json" 2>/dev/null | head -10 || echo "")
    
    if [[ -n "$exposed_secrets" ]]; then
        print_color "$YELLOW" "⚠ Resources with potentially sensitive values in plan:"
        echo "$exposed_secrets" | while read -r resource; do
            if [[ -n "$resource" ]]; then
                print_color "$YELLOW" "  ⚠ $resource"
            fi
        done
        print_color "$BLUE" "  ℹ Ensure sensitive values use sensitive = true or are stored in Secrets Manager"
        echo ""
    else
        print_color "$GREEN" "✓ No obvious sensitive data exposure detected"
    fi
}

#######################################
# Clean up temporary files
# Arguments:
#   $1 - Terraform directory
#######################################
cleanup() {
    local tf_dir="$1"
    
    # Optionally clean up plan files
    if [[ -f "${tf_dir}/${PLAN_JSON_FILE}" ]]; then
        rm -f "${tf_dir}/${PLAN_JSON_FILE}"
    fi
}

#######################################
# Main execution
#######################################
main() {
    local environment="${1:-}"
    local tf_dir="${2:-terraform/main}"
    local exit_code=0
    
    # Validate arguments
    if [[ -z "$environment" ]]; then
        print_color "$RED" "ERROR: Environment name is required"
        usage
    fi
    
    # Resolve terraform directory path
    if [[ ! "$tf_dir" = /* ]]; then
        tf_dir="${PROJECT_ROOT}/${tf_dir}"
    fi
    
    if [[ ! -d "$tf_dir" ]]; then
        print_color "$RED" "ERROR: Terraform directory not found: $tf_dir"
        exit 2
    fi
    
    print_color "$BLUE" "╔═══════════════════════════════════════════════════════════════╗"
    print_color "$BLUE" "║          Terraform Plan Verification Script                   ║"
    print_color "$BLUE" "║          Environment: $(printf '%-38s' "$environment")║"
    print_color "$BLUE" "╚═══════════════════════════════════════════════════════════════╝"
    
    # Check dependencies
    check_dependencies
    
    # Generate plan
    generate_plan "$tf_dir" "$environment"
    
    local plan_json="${tf_dir}/${PLAN_JSON_FILE}"
    
    # Run verification checks
    if ! check_deletions "$plan_json"; then
        exit_code=1
    fi
    
    verify_resource_counts "$plan_json"
    
    if ! check_security_groups "$plan_json"; then
        exit_code=1
    fi
    
    check_sensitive_data "$plan_json"
    
    # Print final result
    print_header "Verification Result"
    
    if [[ $exit_code -eq 0 ]]; then
        print_color "$GREEN" "✓ All plan verification checks PASSED"
        print_color "$GREEN" "  The plan is safe to apply for environment: $environment"
    else
        print_color "$RED" "✗ Plan verification FAILED"
        print_color "$RED" "  Review the warnings above before applying."
        print_color "$YELLOW" "  Consider running: terraform plan -var-file=terraform/environments/${environment}.tfvars"
    fi
    
    echo ""
    
    # Cleanup (keep plan file for potential apply)
    # cleanup "$tf_dir"
    
    exit $exit_code
}

# Run main function
main "$@"
