# =============================================================================
# DNS Record
# =============================================================================

resource "cloudflare_record" "supabase" {
  zone_id = var.cloudflare_zone_id
  name    = var.subdomain
  type    = "A"
  content = hcloud_server.supabase.ipv4_address
  ttl     = 300
  proxied = false # WICHTIG: Nicht proxied für WebSocket Support!

  comment = "Supabase Self-Hosted - Managed by Terraform"
}

# AAAA Record für IPv6 (Hetzner Server haben immer IPv6)
resource "cloudflare_record" "supabase_ipv6" {
  zone_id = var.cloudflare_zone_id
  name    = var.subdomain
  type    = "AAAA"
  content = hcloud_server.supabase.ipv6_address
  ttl     = 300
  proxied = false

  comment = "Supabase Self-Hosted IPv6 - Managed by Terraform"
}

# CNAME für Portainer (portainer.api.bsitservices.de)
resource "cloudflare_record" "portainer" {
  zone_id = var.cloudflare_zone_id
  name    = "portainer.${var.subdomain}"
  type    = "CNAME"
  content = "${var.subdomain}.${var.domain}"
  ttl     = 300
  proxied = false

  comment = "Portainer Management UI - Managed by Terraform"
}

# CNAME für Uptime Kuma / Status (status.api.bsitservices.de)
resource "cloudflare_record" "status" {
  zone_id = var.cloudflare_zone_id
  name    = "status.${var.subdomain}"
  type    = "CNAME"
  content = "${var.subdomain}.${var.domain}"
  ttl     = 300
  proxied = false

  comment = "Uptime Kuma Status Page - Managed by Terraform"
}

# =============================================================================
# Health Check
# =============================================================================

resource "cloudflare_healthcheck" "supabase" {
  zone_id     = var.cloudflare_zone_id
  name        = "supabase-${var.environment}-health"
  address     = "${var.subdomain}.${var.domain}"
  type        = "HTTPS"
  description = "Supabase API Health Check"

  # HTTP-spezifische Einstellungen
  method           = "GET"
  path             = "/rest/v1/"
  expected_codes   = ["200", "401"] # 401 = API Key fehlt, aber Service läuft
  follow_redirects = true

  check_regions         = ["WEU", "ENAM"]
  consecutive_fails     = 3
  consecutive_successes = 2
  interval              = 60
  timeout               = 10
  suspended             = false
}
