#!/bin/bash
# ============================================================================
# Security Compliance Scanner for LiteLLM AWS Infrastructure
# ============================================================================
# This script runs Checkov security scans against Terraform files to verify
# compliance with security best practices including:
# - S3 bucket encryption and public access blocks
# - RDS encryption at rest and in transit
# - RDS IAM authentication
# - Security group least-privilege rules
#
# ============================================================================

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="${PROJECT_ROOT}/terraform"
BOOTSTRAP_DIR="${TERRAFORM_DIR}/bootstrap"
MAIN_DIR="${TERRAFORM_DIR}/main"
OUTPUT_DIR="${PROJECT_ROOT}/.security-scan"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Exit codes
EXIT_SUCCESS=0
EXIT_FAILURE=1
EXIT_CHECKOV_NOT_INSTALLED=2
EXIT_NO_TERRAFORM_FILES=3

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    echo -e "\n${BLUE}============================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# ============================================================================
# Check Prerequisites
# ============================================================================

check_checkov_installed() {
    print_header "Checking Prerequisites"
    
    if command -v checkov &> /dev/null; then
        CHECKOV_VERSION=$(checkov --version 2>/dev/null || echo "unknown")
        print_success "Checkov is installed (version: ${CHECKOV_VERSION})"
        return 0
    else
        print_error "Checkov is not installed"
        echo ""
        echo "Please install Checkov using one of the following methods:"
        echo ""
        echo "  Using pip:"
        echo "    pip install checkov"
        echo ""
        echo "  Using pip3:"
        echo "    pip3 install checkov"
        echo ""
        echo "  Using pipx (recommended for isolation):"
        echo "    pipx install checkov"
        echo ""
        echo "  Using Homebrew (macOS):"
        echo "    brew install checkov"
        echo ""
        echo "  Using Docker:"
        echo "    docker pull bridgecrew/checkov"
        echo "    docker run --tty --rm --volume \$(pwd):/tf bridgecrew/checkov --directory /tf"
        echo ""
        echo "For more information, see: https://www.checkov.io/2.Basics/Installing%20Checkov.html"
        return $EXIT_CHECKOV_NOT_INSTALLED
    fi
}

check_terraform_files() {
    print_header "Checking Terraform Files"
    
    local has_files=false
    
    if [[ -d "$BOOTSTRAP_DIR" ]] && ls "$BOOTSTRAP_DIR"/*.tf &> /dev/null; then
        print_success "Found Terraform files in bootstrap directory"
        has_files=true
    else
        print_warning "No Terraform files found in bootstrap directory"
    fi
    
    if [[ -d "$MAIN_DIR" ]] && ls "$MAIN_DIR"/*.tf &> /dev/null; then
        print_success "Found Terraform files in main directory"
        has_files=true
    else
        print_warning "No Terraform files found in main directory"
    fi
    
    if [[ "$has_files" == "false" ]]; then
        print_error "No Terraform files found to scan"
        return $EXIT_NO_TERRAFORM_FILES
    fi
    
    return 0
}

# ============================================================================
# Security Checks Configuration
# ============================================================================

# Define the key security checks we care about for LiteLLM deployment
# These map to the requirements in the design document

# S3 Security Checks
S3_CHECKS=(
    "CKV_AWS_18"   # Ensure the S3 bucket has access logging enabled
    "CKV_AWS_19"   # Ensure the S3 bucket has server-side encryption enabled
    "CKV_AWS_20"   # Ensure the S3 bucket does not have a public read ACL
    "CKV_AWS_21"   # Ensure the S3 bucket has versioning enabled
    "CKV_AWS_53"   # Ensure S3 bucket has block public ACLS enabled
    "CKV_AWS_54"   # Ensure S3 bucket has block public policy enabled
    "CKV_AWS_55"   # Ensure S3 bucket has ignore public ACLs enabled
    "CKV_AWS_56"   # Ensure S3 bucket has 'restrict_public_buckets' enabled
    "CKV_AWS_145"  # Ensure that S3 buckets are encrypted with KMS by default
)

# RDS Security Checks
RDS_CHECKS=(
    "CKV_AWS_16"   # Ensure all data stored in the RDS bucket is securely encrypted at rest
    "CKV_AWS_17"   # Ensure all data stored in RDS is not publicly accessible
    "CKV_AWS_118"  # Ensure that enhanced monitoring is enabled for RDS instances
    "CKV_AWS_129"  # Ensure that respective logs of Amazon RDS are enabled
    "CKV_AWS_157"  # Ensure that RDS DB cluster has IAM authentication enabled
    "CKV_AWS_161"  # Ensure RDS database has IAM authentication enabled
    "CKV_AWS_162"  # Ensure RDS cluster has deletion protection enabled
    "CKV_AWS_226"  # Ensure RDS PostgreSQL/MySQL instances use a non-default parameter group
    "CKV_AWS_354"  # Ensure RDS Performance Insights are encrypted using KMS CMKs
)

# Security Group Checks
SECURITY_GROUP_CHECKS=(
    "CKV_AWS_23"   # Ensure every security group and rule has a description
    "CKV_AWS_24"   # Ensure no security groups allow ingress from 0.0.0.0:0 to port 22
    "CKV_AWS_25"   # Ensure no security groups allow ingress from 0.0.0.0:0 to port 3389
    "CKV_AWS_260"  # Ensure no security groups allow ingress from 0.0.0.0:0 to port 80
    "CKV_AWS_261"  # Ensure no security groups allow ingress from 0.0.0.0:0 to port 443
    "CKV_AWS_277"  # Ensure no security groups allow ingress from 0.0.0.0:0 to any port
    "CKV2_AWS_5"   # Ensure Security Groups are attached to another resource
)

# ECS Security Checks
ECS_CHECKS=(
    "CKV_AWS_65"   # Ensure ECS task definition containers do not have privileged access
    "CKV_AWS_97"   # Ensure ECS task definition has CPU limit
    "CKV_AWS_99"   # Ensure ECS Fargate services runs on the latest Fargate platform version
    "CKV_AWS_249"  # Ensure ECS Task Definition has logging configuration
)

# ALB Security Checks
ALB_CHECKS=(
    "CKV_AWS_2"    # Ensure ALB protocol is HTTPS
    "CKV_AWS_91"   # Ensure the ELBv2 (Application/Network) has access logging enabled
    "CKV_AWS_103"  # Ensure that load balancer is using at least TLS 1.2
    "CKV_AWS_131"  # Ensure that ALB drops HTTP headers
)

# KMS and Secrets Checks
SECRETS_CHECKS=(
    "CKV_AWS_149"  # Ensure that Secrets Manager secret is encrypted using KMS CMK
    "CKV2_AWS_57"  # Ensure Secrets Manager secrets should have automatic rotation enabled
)

# ============================================================================
# Run Checkov Scans
# ============================================================================

setup_output_directory() {
    mkdir -p "$OUTPUT_DIR"
    print_info "Output directory: $OUTPUT_DIR"
}

run_checkov_scan() {
    local target_dir="$1"
    local module_name="$2"
    local output_file="${OUTPUT_DIR}/${module_name}-results"
    
    print_header "Scanning ${module_name} Module"
    print_info "Directory: ${target_dir}"
    
    if [[ ! -d "$target_dir" ]]; then
        print_warning "Directory does not exist: ${target_dir}"
        return 0
    fi
    
    # Build the Checkov command
    local checkov_cmd=(
        checkov
        --directory "$target_dir"
        --framework terraform
        --compact
        --output cli
        --output json
        --output-file-path "$OUTPUT_DIR"
        --output-bc-ids
    )
    
    # Add skip file if it exists
    local skip_file="${SCRIPT_DIR}/.checkov-baseline.skip"
    if [[ -f "$skip_file" ]]; then
        checkov_cmd+=(--skip-check "$(cat "$skip_file" | tr '\n' ',' | sed 's/,$//')")
        print_info "Using baseline skip file: ${skip_file}"
    fi
    
    # Run Checkov (allow failures - we'll process the results)
    set +e
    "${checkov_cmd[@]}" 2>&1 | tee "${output_file}.log"
    local scan_result=$?
    set -e
    
    # Move the JSON output to a named file
    if [[ -f "${OUTPUT_DIR}/results_cli.json" ]]; then
        mv "${OUTPUT_DIR}/results_cli.json" "${OUTPUT_DIR}/${module_name}-results.json"
    fi
    
    return $scan_result
}

# ============================================================================
# Generate Summary Report
# ============================================================================

generate_summary() {
    print_header "Security Scan Summary"
    
    local total_passed=0
    local total_failed=0
    local total_skipped=0
    
    # Process each results file
    for results_file in "${OUTPUT_DIR}"/*-results.json; do
        if [[ -f "$results_file" ]]; then
            local module_name=$(basename "$results_file" -results.json)
            
            # Extract counts using jq if available, otherwise use grep
            if command -v jq &> /dev/null; then
                local passed=$(jq -r '.results.passed_checks | length // 0' "$results_file" 2>/dev/null || echo 0)
                local failed=$(jq -r '.results.failed_checks | length // 0' "$results_file" 2>/dev/null || echo 0)
                local skipped=$(jq -r '.results.skipped_checks | length // 0' "$results_file" 2>/dev/null || echo 0)
            else
                local passed=$(grep -c '"check_result": {"result": "PASSED"' "$results_file" 2>/dev/null || echo 0)
                local failed=$(grep -c '"check_result": {"result": "FAILED"' "$results_file" 2>/dev/null || echo 0)
                local skipped=$(grep -c '"check_result": {"result": "SKIPPED"' "$results_file" 2>/dev/null || echo 0)
            fi
            
            echo -e "${BLUE}${module_name}:${NC}"
            echo -e "  ${GREEN}Passed:${NC}  $passed"
            echo -e "  ${RED}Failed:${NC}  $failed"
            echo -e "  ${YELLOW}Skipped:${NC} $skipped"
            echo ""
            
            total_passed=$((total_passed + passed))
            total_failed=$((total_failed + failed))
            total_skipped=$((total_skipped + skipped))
        fi
    done
    
    echo -e "${BLUE}────────────────────────────────────────────────────${NC}"
    echo -e "${BLUE}TOTAL:${NC}"
    echo -e "  ${GREEN}Passed:${NC}  $total_passed"
    echo -e "  ${RED}Failed:${NC}  $total_failed"
    echo -e "  ${YELLOW}Skipped:${NC} $total_skipped"
    
    # Key security check verification
    print_header "Key Security Compliance Status"
    
    verify_security_category "S3 Encryption & Public Access" "${S3_CHECKS[@]}"
    verify_security_category "RDS Encryption & IAM Auth" "${RDS_CHECKS[@]}"
    verify_security_category "Security Group Rules" "${SECURITY_GROUP_CHECKS[@]}"
    verify_security_category "ECS Task Security" "${ECS_CHECKS[@]}"
    verify_security_category "ALB TLS Configuration" "${ALB_CHECKS[@]}"
    verify_security_category "Secrets Encryption" "${SECRETS_CHECKS[@]}"
    
    # Return appropriate exit code
    if [[ $total_failed -gt 0 ]]; then
        print_error "Security scan completed with $total_failed failures"
        return $EXIT_FAILURE
    else
        print_success "Security scan completed successfully with no failures"
        return $EXIT_SUCCESS
    fi
}

verify_security_category() {
    local category_name="$1"
    shift
    local checks=("$@")
    
    local category_passed=0
    local category_failed=0
    local category_missing=0
    
    for check in "${checks[@]}"; do
        local found=false
        for results_file in "${OUTPUT_DIR}"/*-results.json; do
            if [[ -f "$results_file" ]]; then
                if grep -q "\"${check}\"" "$results_file" 2>/dev/null; then
                    found=true
                    if grep -q "\"${check}\".*\"result\": \"PASSED\"" "$results_file" 2>/dev/null; then
                        category_passed=$((category_passed + 1))
                    elif grep -q "\"${check}\".*\"result\": \"FAILED\"" "$results_file" 2>/dev/null; then
                        category_failed=$((category_failed + 1))
                    fi
                    break
                fi
            fi
        done
        if [[ "$found" == "false" ]]; then
            category_missing=$((category_missing + 1))
        fi
    done
    
    if [[ $category_failed -gt 0 ]]; then
        print_error "$category_name: $category_failed failed, $category_passed passed"
    elif [[ $category_passed -gt 0 ]]; then
        print_success "$category_name: $category_passed passed"
    else
        print_info "$category_name: No applicable checks (resources may not be defined locally)"
    fi
}

# ============================================================================
# Create Baseline Skip File
# ============================================================================

create_baseline() {
    print_header "Creating Baseline Skip File"
    
    local skip_file="${SCRIPT_DIR}/.checkov-baseline.skip"
    
    echo "# Checkov baseline skip file" > "$skip_file"
    echo "# Add check IDs to skip (one per line)" >> "$skip_file"
    echo "# These checks have been reviewed and accepted as baseline" >> "$skip_file"
    echo "#" >> "$skip_file"
    echo "# Example:" >> "$skip_file"
    echo "# CKV_AWS_18  # S3 access logging - handled by CloudTrail" >> "$skip_file"
    
    print_success "Created baseline file: $skip_file"
    print_info "Edit this file to add checks you want to skip in future scans"
}

# ============================================================================
# Usage Information
# ============================================================================

show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Security compliance scanner for LiteLLM AWS Terraform infrastructure.
Runs Checkov against Terraform files to verify security best practices.

OPTIONS:
    -h, --help           Show this help message
    -b, --bootstrap      Scan only the bootstrap module
    -m, --main           Scan only the main module
    -a, --all            Scan all modules (default)
    --create-baseline    Create a baseline skip file for accepted findings
    -o, --output DIR     Output directory for results (default: .security-scan)
    -v, --verbose        Enable verbose output

EXAMPLES:
    $(basename "$0")                    # Scan all Terraform modules
    $(basename "$0") --bootstrap        # Scan only bootstrap module
    $(basename "$0") --main             # Scan only main module
    $(basename "$0") --create-baseline  # Create baseline skip file

EXIT CODES:
    0   All checks passed
    1   One or more checks failed
    2   Checkov not installed
    3   No Terraform files found

REPORTS:
    Results are saved to ${OUTPUT_DIR}/
    - *-results.json    JSON format results
    - *-results.log     CLI output logs

EOF
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
    local scan_bootstrap=true
    local scan_main=true
    local create_baseline_flag=false
    local verbose=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -b|--bootstrap)
                scan_bootstrap=true
                scan_main=false
                shift
                ;;
            -m|--main)
                scan_bootstrap=false
                scan_main=true
                shift
                ;;
            -a|--all)
                scan_bootstrap=true
                scan_main=true
                shift
                ;;
            --create-baseline)
                create_baseline_flag=true
                shift
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -v|--verbose)
                verbose=true
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    print_header "LiteLLM AWS Security Compliance Scanner"
    print_info "Project root: ${PROJECT_ROOT}"
    
    # Create baseline and exit if requested
    if [[ "$create_baseline_flag" == "true" ]]; then
        create_baseline
        exit 0
    fi
    
    # Check prerequisites
    check_checkov_installed || exit $?
    check_terraform_files || exit $?
    
    # Setup output directory
    setup_output_directory
    
    # Track overall success
    local overall_result=0
    
    # Run scans
    if [[ "$scan_bootstrap" == "true" ]]; then
        run_checkov_scan "$BOOTSTRAP_DIR" "bootstrap" || overall_result=1
    fi
    
    if [[ "$scan_main" == "true" ]]; then
        run_checkov_scan "$MAIN_DIR" "main" || overall_result=1
    fi
    
    # Generate summary
    generate_summary || overall_result=$?
    
    print_header "Scan Complete"
    print_info "Detailed results saved to: ${OUTPUT_DIR}"
    
    exit $overall_result
}

# Run main function
main "$@"
