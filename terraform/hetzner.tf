# =============================================================================
# SSH Key
# =============================================================================

resource "hcloud_ssh_key" "main" {
  name       = "supabase-${var.environment}"
  public_key = var.ssh_public_key
}

# =============================================================================
# Firewall
# =============================================================================

resource "hcloud_firewall" "supabase" {
  name = "supabase-${var.environment}-firewall"

  # SSH - nur Admin-IPs
  rule {
    description = "SSH"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.admin_ips
  }

  # HTTP - Let's Encrypt ACME Challenge
  rule {
    description = "HTTP (Let's Encrypt)"
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS - Caddy Reverse Proxy (alle Services)
  rule {
    description = "HTTPS (Caddy)"
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS/UDP für HTTP/3 (QUIC)
  rule {
    description = "HTTP/3 (QUIC)"
    direction   = "in"
    protocol    = "udp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  # Portainer und Uptime Kuma laufen jetzt über Caddy (Port 443)
  # Keine separaten Ports mehr nötig!

  # ICMP (Ping)
  rule {
    description = "ICMP"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
}

# =============================================================================
# Server
# =============================================================================

resource "hcloud_server" "supabase" {
  name        = "supabase-${var.environment}"
  image       = "ubuntu-24.04"
  server_type = var.server_type
  location    = var.location

  ssh_keys     = [hcloud_ssh_key.main.id]
  firewall_ids = [hcloud_firewall.supabase.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  user_data = templatefile("${path.module}/../cloud-init/user-data.yaml.tpl", {
    # Domain
    domain = "${var.subdomain}.${var.domain}"

    # Restore
    restore_from_backup = var.restore_from_backup
    backup_date         = var.backup_date

    # Eingebettete Config-Dateien (gerendert via templatefile)
    supabase_env = templatefile("${path.module}/../cloud-init/configs/supabase.env.tpl", {
      postgres_password     = var.postgres_password
      jwt_secret            = var.jwt_secret
      anon_key              = var.anon_key
      service_role_key      = var.service_role_key
      dashboard_username    = var.dashboard_username
      dashboard_password    = var.dashboard_password
      secret_key_base       = var.secret_key_base != "" ? var.secret_key_base : random_password.secret_key_base.result
      vault_enc_key         = var.vault_enc_key != "" ? var.vault_enc_key : random_password.vault_enc_key.result
      logflare_api_key      = var.logflare_api_key != "" ? var.logflare_api_key : random_password.logflare_api_key.result
      domain                = "${var.subdomain}.${var.domain}"
      acme_email            = var.acme_email
      s3_endpoint           = var.s3_endpoint
      s3_endpoint_host      = replace(replace(var.s3_endpoint, "https://", ""), "http://", "")
      s3_region             = var.s3_region
      s3_access_key         = var.s3_access_key
      s3_secret_key         = var.s3_secret_key
      s3_storage_bucket     = var.s3_storage_bucket
      s3_backup_bucket      = var.s3_backup_bucket
      notification_urls     = var.notification_urls
      backup_encryption_key = var.backup_encryption_key
    })

    kong_config = templatefile("${path.module}/../cloud-init/configs/kong.yml.tpl", {
      anon_key           = var.anon_key
      service_role_key   = var.service_role_key
      dashboard_username = var.dashboard_username
      dashboard_password = var.dashboard_password
      acme_email         = var.acme_email
      domain             = "${var.subdomain}.${var.domain}"
    })

    docker_compose_override = file("${path.module}/../cloud-init/configs/docker-compose.override.yml")
    caddyfile               = file("${path.module}/../cloud-init/configs/Caddyfile")
    restore_script          = file("${path.module}/../cloud-init/configs/restore.sh")
  })

  labels = {
    environment = var.environment
    managed_by  = "terraform"
    service     = "supabase"
  }

  lifecycle {
    ignore_changes = [
      ssh_keys,
      user_data
    ]
  }
}

# =============================================================================
# Random Passwords für optionale Secrets
# =============================================================================

resource "random_password" "secret_key_base" {
  length  = 64
  special = false
}

resource "random_password" "vault_enc_key" {
  length  = 32
  special = false
}

resource "random_password" "logflare_api_key" {
  length  = 32
  special = false
}
