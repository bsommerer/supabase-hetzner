# =============================================================================
# Supabase Self-Hosting auf Hetzner
# =============================================================================
#
# Dieses Terraform-Modul erstellt:
# - Hetzner Cloud Server mit Ubuntu 24.04
# - Hetzner Firewall mit nur notwendigen Ports
# - SSH Key für sicheren Zugang
# - Cloudflare DNS Record
# - Cloudflare Health Check
#
# Die VM wird via Cloud-init konfiguriert und startet automatisch:
# - Docker + Docker Compose
# - Supabase (alle Services)
# - Portainer (Container Management)
# - Uptime Kuma (Monitoring)
# - docker-volume-backup (Automatische Backups)
#
# Verwendung:
#   1. terraform.tfvars erstellen (siehe terraform.tfvars.example)
#   2. ./scripts/generate-secrets.sh ausführen
#   3. terraform init
#   4. terraform apply
#
# =============================================================================

# Lokale Variablen für häufig verwendete Werte
locals {
  full_domain = "${var.subdomain}.${var.domain}"

  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Service     = "supabase"
    Project     = "supabase-hetzner"
  }
}

# =============================================================================
# Data Sources
# =============================================================================

# Aktuelle Hetzner Datacenter Informationen (optional)
data "hcloud_location" "selected" {
  name = var.location
}
