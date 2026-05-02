# =============================================================================
# Server Outputs
# =============================================================================

output "server_ip" {
  description = "IPv4 Adresse des Supabase Servers"
  value       = hcloud_server.supabase.ipv4_address
}

output "server_ipv6" {
  description = "IPv6 Adresse des Supabase Servers"
  value       = hcloud_server.supabase.ipv6_address
}

output "server_id" {
  description = "Hetzner Server ID"
  value       = hcloud_server.supabase.id
}

output "server_name" {
  description = "Server Name"
  value       = hcloud_server.supabase.name
}

output "server_status" {
  description = "Server Status"
  value       = hcloud_server.supabase.status
}

# =============================================================================
# DNS Outputs
# =============================================================================

output "supabase_url" {
  description = "Supabase URL"
  value       = "https://${var.subdomain}.${var.domain}"
}

output "supabase_api_url" {
  description = "Supabase REST API URL"
  value       = "https://${var.subdomain}.${var.domain}/rest/v1"
}

output "supabase_studio_url" {
  description = "Supabase Studio URL"
  value       = "https://${var.subdomain}.${var.domain}"
}

output "portainer_url" {
  description = "Portainer URL (via Caddy Reverse Proxy)"
  value       = "https://portainer.${var.subdomain}.${var.domain}"
}

# =============================================================================
# SSH Outputs
# =============================================================================

output "ssh_command" {
  description = "SSH Befehl zum Verbinden"
  value       = "ssh ubuntu@${hcloud_server.supabase.ipv4_address}"
}

# =============================================================================
# Firewall Outputs
# =============================================================================

output "firewall_id" {
  description = "Hetzner Firewall ID"
  value       = hcloud_firewall.supabase.id
}

# =============================================================================
# SSH Keys Output (für scripts/sync-keys.sh)
# =============================================================================

output "ssh_public_keys" {
  description = "Konfigurierte SSH Public Keys (Quelle der Wahrheit für Server-Zugang)"
  value       = var.ssh_public_keys
}
