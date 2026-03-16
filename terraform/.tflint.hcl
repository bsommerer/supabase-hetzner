# =============================================================================
# TFLint Konfiguration
# =============================================================================
# Statische Analyse für Terraform-Code.
#
# Installation: https://github.com/terraform-linters/tflint
# Verwendung:   tflint --chdir=terraform
# =============================================================================

config {
  call_module_type = "local"
}

# Terraform-spezifische Regeln
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Regeln für veraltete/problematische Syntax
rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true

  custom_formats = {}
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_unused_required_providers" {
  enabled = true
}

rule "terraform_standard_module_structure" {
  enabled = false
}
