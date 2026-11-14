# TFLint Configuration for LiteLLM AWS Infrastructure
# ----------------------------------------------------
# This configuration enables the AWS plugin and defines
# rules for Terraform code quality and best practices.
#

# Use the AWS plugin for AWS-specific checks
plugin "aws" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Core TFLint Rules
# -----------------

# Disallow deprecated (0.11-style) interpolation
rule "terraform_deprecated_interpolation" {
  enabled = true
}

# Disallow legacy dot index syntax
rule "terraform_deprecated_index" {
  enabled = true
}

# Disallow variables, data sources, and locals that are declared but never used
rule "terraform_unused_declarations" {
  enabled = true
}

# Disallow terraform declarations without required_version
rule "terraform_required_version" {
  enabled = true
}

# Require that all providers have version constraints
rule "terraform_required_providers" {
  enabled = true
}

# Ensure that a module complies with the Terraform Standard Module Structure
rule "terraform_standard_module_structure" {
  enabled = true
}

# Enforces naming conventions for resources, data sources, and modules
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Disallow specifying a git or mercurial repository as a module source without a revision
rule "terraform_module_pinned_source" {
  enabled = true
}

# Enforces consistent formatting in comment blocks
rule "terraform_comment_syntax" {
  enabled = true
}

# Require type declarations for variables
rule "terraform_typed_variables" {
  enabled = true
}
