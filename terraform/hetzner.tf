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

  # Portainer läuft über Caddy (Port 443)

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

  firewall_ids = [hcloud_firewall.supabase.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  user_data = templatefile("${path.module}/../cloud-init/user-data.yaml.tpl", {
    domain              = "${var.subdomain}.${var.domain}"
    ssh_public_key      = var.ssh_public_key
    restore_from_backup = var.restore_from_backup
    backup_date         = var.backup_date

    # Config-Dateien gz+b64 kodiert (CRLF→LF für Linux-Kompatibilität)
    supabase_env = base64gzip(replace(templatefile("${path.module}/../cloud-init/configs/supabase.env.tpl", {
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
    }), "\r\n", "\n"))

    docker_compose_override = base64gzip(replace(file("${path.module}/../cloud-init/configs/docker-compose.override.yml"), "\r\n", "\n"))
    caddyfile               = base64gzip(replace(file("${path.module}/../cloud-init/configs/Caddyfile"), "\r\n", "\n"))
    restore_script          = base64gzip(replace(file("${path.module}/../cloud-init/configs/restore.sh"), "\r\n", "\n"))
  })

  labels = {
    environment = var.environment
    managed_by  = "terraform"
    service     = "supabase"
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
