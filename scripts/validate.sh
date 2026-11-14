#!/bin/bash
#
# Terraform Static Analysis Script
# ---------------------------------
# This script runs static analysis checks on Terraform configurations
# including formatting, validation, and linting with tflint.
#
# Usage: ./scripts/validate.sh
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

# Track overall status
OVERALL_STATUS=0

# Print section header
print_header() {
    echo ""
    echo "=============================================="
    echo -e "${YELLOW}$1${NC}"
    echo "=============================================="
}

# Print success message
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Print error message
print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Print info message
print_info() {
    echo -e "  $1"
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Verify Terraform is installed
check_terraform() {
    print_header "Checking Prerequisites"
    
    if ! command_exists terraform; then
        print_error "Terraform is not installed or not in PATH"
        exit 1
    fi
    
    TERRAFORM_VERSION=$(terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4 || terraform version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    print_success "Terraform version: $TERRAFORM_VERSION"
}

# Run terraform fmt check
run_terraform_fmt() {
    print_header "Running Terraform Format Check"
    
    cd "$TERRAFORM_DIR"
    
    if terraform fmt -check -recursive -diff; then
        print_success "All Terraform files are properly formatted"
    else
        print_error "Terraform formatting issues found"
        print_info "Run 'terraform fmt -recursive' in the terraform directory to fix"
        OVERALL_STATUS=1
    fi
}

# Run terraform init and validate for a module
validate_module() {
    local module_path="$1"
    local module_name="$2"
    
    print_header "Validating $module_name Module"
    
    if [ ! -d "$module_path" ]; then
        print_error "Module directory not found: $module_path"
        OVERALL_STATUS=1
        return
    fi
    
    cd "$module_path"
    
    # Initialize without backend
    print_info "Initializing Terraform (backend=false)..."
    if terraform init -backend=false -input=false >/dev/null 2>&1; then
        print_success "Terraform init successful"
    else
        # Try with more verbose output on failure
        if terraform init -backend=false -input=false; then
            print_success "Terraform init successful"
        else
            print_error "Terraform init failed for $module_name"
            OVERALL_STATUS=1
            return
        fi
    fi
    
    # Validate configuration
    print_info "Running terraform validate..."
    if terraform validate; then
        print_success "Terraform validation passed for $module_name"
    else
        print_error "Terraform validation failed for $module_name"
        OVERALL_STATUS=1
    fi
}

# Run tflint for a module
run_tflint() {
    local module_path="$1"
    local module_name="$2"
    
    print_header "Running TFLint on $module_name Module"
    
    if ! command_exists tflint; then
        print_info "TFLint is not installed - skipping lint checks"
        print_info "Install tflint for additional static analysis:"
        print_info "  https://github.com/terraform-linters/tflint#installation"
        return
    fi
    
    cd "$module_path"
    
    # Check if .tflint.hcl exists, if not use defaults
    local tflint_config=""
    if [ -f ".tflint.hcl" ]; then
        tflint_config="--config=.tflint.hcl"
    elif [ -f "$TERRAFORM_DIR/.tflint.hcl" ]; then
        tflint_config="--config=$TERRAFORM_DIR/.tflint.hcl"
    fi
    
    # Initialize tflint plugins if config exists
    if [ -n "$tflint_config" ]; then
        print_info "Initializing TFLint plugins..."
        tflint --init $tflint_config 2>/dev/null || true
    fi
    
    # Run tflint
    print_info "Running TFLint..."
    if tflint $tflint_config; then
        print_success "TFLint passed for $module_name"
    else
        print_error "TFLint found issues in $module_name"
        OVERALL_STATUS=1
    fi
}

# Main execution
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║     Terraform Static Analysis Validation      ║"
    echo "╚═══════════════════════════════════════════════╝"
    
    # Check prerequisites
    check_terraform
    
    # Run format check across all Terraform files
    run_terraform_fmt
    
    # Validate bootstrap module
    validate_module "$TERRAFORM_DIR/bootstrap" "Bootstrap"
    
    # Run tflint on bootstrap module
    run_tflint "$TERRAFORM_DIR/bootstrap" "Bootstrap"
    
    # Validate main module
    validate_module "$TERRAFORM_DIR/main" "Main"
    
    # Run tflint on main module
    run_tflint "$TERRAFORM_DIR/main" "Main"
    
    # Print summary
    print_header "Validation Summary"
    
    if [ $OVERALL_STATUS -eq 0 ]; then
        print_success "All static analysis checks passed!"
        echo ""
        exit 0
    else
        print_error "Some checks failed - please review the output above"
        echo ""
        exit 1
    fi
}

# Run main function
main "$@"
