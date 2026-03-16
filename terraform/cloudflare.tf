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

# CNAME für Portainer (portainer.supabase.example.com)
resource "cloudflare_record" "portainer" {
  zone_id = var.cloudflare_zone_id
  name    = "portainer.${var.subdomain}"
  type    = "CNAME"
  content = "${var.subdomain}.${var.domain}"
  ttl     = 300
  proxied = false

  comment = "Portainer Management UI - Managed by Terraform"
}
