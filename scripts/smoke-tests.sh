#!/bin/bash
#
# LiteLLM Smoke Tests
# ====================
# Service verification script for LiteLLM deployment
#
# Usage:
#   ./smoke-tests.sh <endpoint_url> [options]
#   ./smoke-tests.sh --from-terraform [options]
#
# Options:
#   --from-terraform    Get endpoint URL from terraform output
#   --api-key KEY       API key for authenticated tests (or set LITELLM_API_KEY env var)
#   --timeout SECONDS   Request timeout in seconds (default: 30)
#   --verbose           Show detailed output
#   --help              Show this help message
#
# Environment Variables:
#   LITELLM_API_KEY     API key for authenticated endpoints
#   LITELLM_ENDPOINT    Endpoint URL (alternative to positional argument)
#
# Exit Codes:
#   0 - All tests passed
#   1 - One or more tests failed
#   2 - Invalid arguments or configuration error
#

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

# Default values
DEFAULT_TIMEOUT=30
VERBOSE=false
ENDPOINT_URL=""
API_KEY="${LITELLM_API_KEY:-}"
TIMEOUT="${DEFAULT_TIMEOUT}"
FROM_TERRAFORM=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# =============================================================================
# Helper Functions
# =============================================================================

print_usage() {
    cat << 'EOF'
LiteLLM Smoke Tests
====================
Service verification script for LiteLLM deployment

Usage:
  ./smoke-tests.sh <endpoint_url> [options]
  ./smoke-tests.sh --from-terraform [options]

Options:
  --from-terraform    Get endpoint URL from terraform output
  --api-key KEY       API key for authenticated tests (or set LITELLM_API_KEY env var)
  --timeout SECONDS   Request timeout in seconds (default: 30)
  --verbose           Show detailed output
  --help              Show this help message

Environment Variables:
  LITELLM_API_KEY     API key for authenticated endpoints
  LITELLM_ENDPOINT    Endpoint URL (alternative to positional argument)

Exit Codes:
  0 - All tests passed
  1 - One or more tests failed
  2 - Invalid arguments or configuration error
EOF
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# Get endpoint from terraform output
get_terraform_endpoint() {
    local terraform_dir="${TERRAFORM_DIR:-terraform/main}"
    
    if [[ ! -d "$terraform_dir" ]]; then
        echo "Error: Terraform directory not found: $terraform_dir" >&2
        return 1
    fi
    
    log_verbose "Getting endpoint from terraform output in $terraform_dir"
    
    # Try to get the litellm_endpoint output
    local endpoint
    endpoint=$(cd "$terraform_dir" && terraform output -raw litellm_endpoint 2>/dev/null) || {
        # Fallback to alb_dns_name
        endpoint=$(cd "$terraform_dir" && terraform output -raw alb_dns_name 2>/dev/null) || {
            echo "Error: Could not get endpoint from terraform output" >&2
            return 1
        }
        # Prepend http:// if alb_dns_name doesn't have protocol
        if [[ ! "$endpoint" =~ ^https?:// ]]; then
            endpoint="http://${endpoint}"
        fi
    }
    
    echo "$endpoint"
}

# Make HTTP request and capture response
make_request() {
    local method="$1"
    local url="$2"
    local data="${3:-}"
    local auth_header="${4:-}"
    
    local curl_args=(
        -s
        -w "\n%{http_code}"
        -X "$method"
        --connect-timeout "$TIMEOUT"
        --max-time "$TIMEOUT"
    )
    
    if [[ -n "$auth_header" ]]; then
        curl_args+=(-H "$auth_header")
    fi
    
    if [[ -n "$data" ]]; then
        curl_args+=(-H "Content-Type: application/json")
        curl_args+=(-d "$data")
    fi
    
    curl_args+=("$url")
    
    log_verbose "curl ${curl_args[*]}"
    
    curl "${curl_args[@]}" 2>/dev/null || echo -e "\n000"
}

# Parse response to get body and status code
parse_response() {
    local response="$1"
    local status_code
    local body
    
    # Last line is status code
    status_code=$(echo "$response" | tail -1)
    # Everything else is body
    body=$(echo "$response" | sed '$d')
    
    echo "$status_code"
    echo "$body"
}

# =============================================================================
# Test Functions
# =============================================================================

test_health_liveliness() {
    log_info "Testing /health/liveliness endpoint..."
    
    local url="${ENDPOINT_URL}/health/liveliness"
    local response
    local status_code
    local body
    
    response=$(make_request "GET" "$url")
    status_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    
    log_verbose "Status: $status_code"
    log_verbose "Body: $body"
    
    if [[ "$status_code" == "200" ]]; then
        log_success "/health/liveliness - Status: 200 OK"
        ((TESTS_PASSED++))
        return 0
    else
        log_fail "/health/liveliness - Expected: 200, Got: $status_code"
        if [[ -n "$body" ]]; then
            log_verbose "Response body: $body"
        fi
        ((TESTS_FAILED++))
        return 1
    fi
}

test_health_readiness() {
    log_info "Testing /health/readiness endpoint..."
    
    local url="${ENDPOINT_URL}/health/readiness"
    local response
    local status_code
    local body
    
    response=$(make_request "GET" "$url")
    status_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    
    log_verbose "Status: $status_code"
    log_verbose "Body: $body"
    
    if [[ "$status_code" == "200" ]]; then
        log_success "/health/readiness - Status: 200 OK"
        ((TESTS_PASSED++))
        return 0
    else
        log_fail "/health/readiness - Expected: 200, Got: $status_code"
        if [[ -n "$body" ]]; then
            log_verbose "Response body: $body"
        fi
        ((TESTS_FAILED++))
        return 1
    fi
}

test_models_endpoint() {
    log_info "Testing /v1/models endpoint (authenticated)..."
    
    if [[ -z "$API_KEY" ]]; then
        log_skip "/v1/models - No API key provided (set LITELLM_API_KEY or use --api-key)"
        ((TESTS_SKIPPED++))
        return 0
    fi
    
    local url="${ENDPOINT_URL}/v1/models"
    local auth_header="Authorization: Bearer ${API_KEY}"
    local response
    local status_code
    local body
    
    response=$(make_request "GET" "$url" "" "$auth_header")
    status_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    
    log_verbose "Status: $status_code"
    log_verbose "Body: $body"
    
    if [[ "$status_code" == "200" ]]; then
        # Verify response contains expected structure
        if echo "$body" | grep -q '"data"'; then
            log_success "/v1/models - Status: 200 OK, Response contains 'data' field"
            ((TESTS_PASSED++))
            return 0
        else
            log_warn "/v1/models - Status: 200 but response structure unexpected"
            log_verbose "Expected 'data' field in response"
            ((TESTS_PASSED++))
            return 0
        fi
    elif [[ "$status_code" == "401" ]]; then
        log_fail "/v1/models - Authentication failed (401). Check API key."
        ((TESTS_FAILED++))
        return 1
    else
        log_fail "/v1/models - Expected: 200, Got: $status_code"
        if [[ -n "$body" ]]; then
            log_verbose "Response body: $body"
        fi
        ((TESTS_FAILED++))
        return 1
    fi
}

test_chat_completion() {
    log_info "Testing /v1/chat/completions endpoint (authenticated)..."
    
    if [[ -z "$API_KEY" ]]; then
        log_skip "/v1/chat/completions - No API key provided (set LITELLM_API_KEY or use --api-key)"
        ((TESTS_SKIPPED++))
        return 0
    fi
    
    local url="${ENDPOINT_URL}/v1/chat/completions"
    local auth_header="Authorization: Bearer ${API_KEY}"
    
    # Simple test request - uses default model
    local request_body='{
        "model": "default",
        "messages": [
            {
                "role": "user",
                "content": "Say hello in exactly one word."
            }
        ],
        "max_tokens": 10
    }'
    
    local response
    local status_code
    local body
    
    response=$(make_request "POST" "$url" "$request_body" "$auth_header")
    status_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    
    log_verbose "Status: $status_code"
    log_verbose "Body: $body"
    
    if [[ "$status_code" == "200" ]]; then
        # Verify response contains expected structure
        if echo "$body" | grep -q '"choices"'; then
            log_success "/v1/chat/completions - Status: 200 OK, Response contains 'choices' field"
            ((TESTS_PASSED++))
            return 0
        else
            log_warn "/v1/chat/completions - Status: 200 but response structure unexpected"
            log_verbose "Expected 'choices' field in response"
            ((TESTS_PASSED++))
            return 0
        fi
    elif [[ "$status_code" == "401" ]]; then
        log_fail "/v1/chat/completions - Authentication failed (401). Check API key."
        ((TESTS_FAILED++))
        return 1
    elif [[ "$status_code" == "400" ]]; then
        # 400 might indicate model not found or invalid request
        log_fail "/v1/chat/completions - Bad request (400). Check model configuration."
        if [[ -n "$body" ]]; then
            log_verbose "Response body: $body"
        fi
        ((TESTS_FAILED++))
        return 1
    elif [[ "$status_code" == "000" ]]; then
        log_fail "/v1/chat/completions - Connection failed or timeout"
        ((TESTS_FAILED++))
        return 1
    else
        log_fail "/v1/chat/completions - Expected: 200, Got: $status_code"
        if [[ -n "$body" ]]; then
            log_verbose "Response body: $body"
        fi
        ((TESTS_FAILED++))
        return 1
    fi
}

# =============================================================================
# Main Script
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from-terraform)
                FROM_TERRAFORM=true
                shift
                ;;
            --api-key)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --api-key requires a value" >&2
                    exit 2
                fi
                API_KEY="$2"
                shift 2
                ;;
            --timeout)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --timeout requires a value" >&2
                    exit 2
                fi
                TIMEOUT="$2"
                shift 2
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            -*)
                echo "Error: Unknown option: $1" >&2
                print_usage
                exit 2
                ;;
            *)
                if [[ -z "$ENDPOINT_URL" ]]; then
                    ENDPOINT_URL="$1"
                else
                    echo "Error: Unexpected argument: $1" >&2
                    exit 2
                fi
                shift
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    
    # Get endpoint URL
    if [[ "$FROM_TERRAFORM" == "true" ]]; then
        ENDPOINT_URL=$(get_terraform_endpoint) || exit 2
    elif [[ -z "$ENDPOINT_URL" ]]; then
        # Try environment variable
        ENDPOINT_URL="${LITELLM_ENDPOINT:-}"
    fi
    
    if [[ -z "$ENDPOINT_URL" ]]; then
        echo "Error: No endpoint URL provided" >&2
        echo "Usage: $0 <endpoint_url> or $0 --from-terraform" >&2
        exit 2
    fi
    
    # Remove trailing slash if present
    ENDPOINT_URL="${ENDPOINT_URL%/}"
    
    echo ""
    echo "========================================"
    echo "  LiteLLM Smoke Tests"
    echo "========================================"
    echo ""
    log_info "Endpoint: $ENDPOINT_URL"
    log_info "Timeout: ${TIMEOUT}s"
    if [[ -n "$API_KEY" ]]; then
        log_info "API Key: ***${API_KEY: -4}"
    else
        log_warn "API Key: Not provided (authenticated tests will be skipped)"
    fi
    echo ""
    echo "----------------------------------------"
    echo ""
    
    # Run tests
    test_health_liveliness || true
    echo ""
    
    test_health_readiness || true
    echo ""
    
    test_models_endpoint || true
    echo ""
    
    test_chat_completion || true
    echo ""
    
    # Print summary
    echo "----------------------------------------"
    echo ""
    echo "Test Summary:"
    echo -e "  ${GREEN}Passed:${NC}  $TESTS_PASSED"
    echo -e "  ${RED}Failed:${NC}  $TESTS_FAILED"
    echo -e "  ${YELLOW}Skipped:${NC} $TESTS_SKIPPED"
    echo ""
    
    if [[ $TESTS_FAILED -gt 0 ]]; then
        log_fail "Some tests failed!"
        exit 1
    else
        log_success "All tests passed!"
        exit 0
    fi
}

main "$@"
