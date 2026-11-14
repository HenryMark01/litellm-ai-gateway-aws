# ============================================================================
# DNS and Certificate Configuration
# ============================================================================
# This file configures ACM certificates and Route53 DNS records for custom
# domain support. All resources are conditional based on whether a domain
# name and/or hosted zone ID are provided.
#
# USAGE PATTERNS:
# 1. No custom domain (default): Use ALB DNS name directly
#    - domain_name = "" (default)
#    - hosted_zone_id = "" (default)
#    - create_acm_certificate = false (default)
#
# 2. Custom domain with new certificate:
#    - domain_name = "api.example.com"
#    - hosted_zone_id = "Z1234567890ABC"
#    - create_acm_certificate = true
#
# 3. Custom domain with existing certificate:
#    - domain_name = "api.example.com"
#    - hosted_zone_id = "Z1234567890ABC"
#    - create_acm_certificate = false
#    - acm_certificate_arn = "arn:aws:acm:..."
#
# 4. Custom domain without Route53 (manual DNS):
#    - domain_name = "api.example.com"
#    - hosted_zone_id = "" (empty)
#    - create_acm_certificate = true
#    - Manual DNS records required for certificate validation and ALB alias
#
# ============================================================================

# ----------------------------------------------------------------------------
# Local Values
# ----------------------------------------------------------------------------
# Compute derived values for conditional resource creation and certificate
# ARN selection.
# ----------------------------------------------------------------------------

locals {
  # Determine if we should create DNS resources
  # A domain name must be provided to enable any DNS/certificate features
  dns_enabled = var.domain_name != ""

  # Determine if Route53 management is available
  # Requires both domain_name AND hosted_zone_id to be provided
  route53_enabled = local.dns_enabled && var.hosted_zone_id != ""

  # Determine the certificate ARN to pass to the LiteLLM module
  # Priority:
  # 1. If create_acm_certificate is true, use the newly created certificate
  # 2. Otherwise, use the provided acm_certificate_arn (which may be empty)
  effective_certificate_arn = var.create_acm_certificate && local.dns_enabled ? aws_acm_certificate.litellm[0].arn : var.acm_certificate_arn
}

# ----------------------------------------------------------------------------
# Data Source: ALB
# ----------------------------------------------------------------------------
# Fetch the ALB details to get the zone_id needed for Route53 alias records.
# The BerriAI/litellm module exposes alb_dns_name but not zone_id.
# ----------------------------------------------------------------------------

data "aws_lb" "litellm" {
  count = local.route53_enabled ? 1 : 0

  # Match by name - the module uses {tenant}-litellm-{env} naming pattern
  name = "${var.tenant}-litellm-${var.environment}"

  depends_on = [module.litellm]
}

# ----------------------------------------------------------------------------
# ACM Certificate
# ----------------------------------------------------------------------------
# Creates an ACM certificate for the configured domain name when:
# - domain_name is provided (not empty)
# - create_acm_certificate is true
#
# The certificate uses DNS validation, which requires adding CNAME records
# to the domain's DNS. When hosted_zone_id is provided, these records are
# created automatically. Otherwise, manual DNS configuration is required.
#
# ----------------------------------------------------------------------------

resource "aws_acm_certificate" "litellm" {
  count = local.dns_enabled && var.create_acm_certificate ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  # Lifecycle rule to create new certificate before destroying old one
  # This prevents downtime during certificate renewal
  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.additional_tags, {
    Name        = "${var.tenant}-litellm-${var.environment}"
    Environment = var.environment
    Tenant      = var.tenant
    Purpose     = "LiteLLM ALB TLS termination"
  })
}

# ----------------------------------------------------------------------------
# Route53 DNS Validation Records
# ----------------------------------------------------------------------------
# Creates CNAME records in Route53 for ACM certificate DNS validation when:
# - An ACM certificate is being created (create_acm_certificate = true)
# - Route53 hosted zone ID is provided (hosted_zone_id != "")
#
# These records prove domain ownership to ACM, allowing the certificate
# to be issued. The records must remain in place for certificate renewal.
#
# When hosted_zone_id is NOT provided, the domain_validation_options output
# contains the CNAME records that must be added manually to the DNS provider.
#
# ----------------------------------------------------------------------------

resource "aws_route53_record" "acm_validation" {
  # Create validation records only when:
  # 1. We're creating a certificate (dns_enabled && create_acm_certificate)
  # 2. We have Route53 access (route53_enabled)
  for_each = local.dns_enabled && var.create_acm_certificate && local.route53_enabled ? {
    for dvo in aws_acm_certificate.litellm[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = var.hosted_zone_id
}

# ----------------------------------------------------------------------------
# ACM Certificate Validation
# ----------------------------------------------------------------------------
# Waits for the ACM certificate to be validated and issued. This resource
# will timeout if the DNS validation records are not accessible.
#
# TIMEOUT HANDLING:
# - Default timeout: 75 minutes (sufficient for DNS propagation)
# - If validation fails, check that:
#   1. DNS validation records are correctly configured
#   2. DNS has propagated (can take up to 48 hours in worst case)
#   3. The domain is publicly resolvable
#
# When using Route53 (hosted_zone_id provided), validation typically
# completes within 5-10 minutes.
#
# ----------------------------------------------------------------------------

resource "aws_acm_certificate_validation" "litellm" {
  # Only create when we're creating a certificate AND have Route53 for validation
  count = local.dns_enabled && var.create_acm_certificate && local.route53_enabled ? 1 : 0

  certificate_arn         = aws_acm_certificate.litellm[0].arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]

  # Timeout for certificate validation
  # 75 minutes is generous to account for DNS propagation delays
  timeouts {
    create = "75m"
  }
}

# ----------------------------------------------------------------------------
# Route53 A Record (ALB Alias)
# ----------------------------------------------------------------------------
# Creates an A record in Route53 that aliases to the ALB DNS name when:
# - domain_name is provided (not empty)
# - hosted_zone_id is provided (not empty)
#
# ALIAS RECORD BENEFITS:
# - No TTL concerns: AWS automatically updates the IP addresses
# - No additional DNS lookup: Resolves directly to ALB IPs
# - Free: No Route53 query charges for alias records to AWS resources
#
# When hosted_zone_id is NOT provided, the alb_dns_name output should be
# used to manually create a CNAME or A record with the DNS provider.
#
# ----------------------------------------------------------------------------

resource "aws_route53_record" "alb_alias" {
  count = local.route53_enabled ? 1 : 0

  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    # The ALB DNS name from the LiteLLM module
    name = module.litellm.alb_dns_name
    # The ALB hosted zone ID from the data source
    zone_id = data.aws_lb.litellm[0].zone_id
    # Evaluate target health: Route53 will check ALB health
    evaluate_target_health = true
  }
}
