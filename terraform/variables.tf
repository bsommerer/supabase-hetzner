# =============================================================================
# Hetzner Cloud Variablen
# =============================================================================

variable "hcloud_token" {
  description = "Hetzner Cloud API Token"
  type        = string
  sensitive   = true
}

variable "server_type" {
  description = "Hetzner Server Type (cx22 für Test, cpx31 für Produktion)"
  type        = string
  default     = "cx22"

  validation {
    condition     = can(regex("^(cx|cpx|cax|ccx)", var.server_type))
    error_message = "server_type muss ein gültiger Hetzner Server-Typ sein (z.B. cx22, cpx31, cax21)."
  }
}

variable "location" {
  description = "Hetzner Datacenter Location (nbg1, fsn1, hel1)"
  type        = string
  default     = "nbg1"

  validation {
    condition     = contains(["nbg1", "fsn1", "hel1", "ash", "hil"], var.location)
    error_message = "location muss ein gültiger Hetzner-Standort sein: nbg1, fsn1, hel1, ash, hil."
  }
}

variable "ssh_public_keys" {
  description = "Liste von SSH Public Keys für Server-Zugang (ein Eintrag pro Gerät)"
  type        = list(string)

  validation {
    condition     = length(var.ssh_public_keys) >= 1
    error_message = "ssh_public_keys muss mindestens einen Key enthalten — sonst Lockout."
  }
}

variable "admin_ips" {
  description = "Liste von IP-Adressen für Admin-Zugang (SSH, Portainer)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "environment" {
  description = "Umgebung (dev, staging, prod)"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment muss dev, staging oder prod sein."
  }
}

# =============================================================================
# Cloudflare Variablen
# =============================================================================

variable "cloudflare_api_token" {
  description = "Cloudflare API Token mit DNS Edit Berechtigung"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID"
  type        = string
}

variable "domain" {
  description = "Domain Name (z.B. example.com)"
  type        = string
}

variable "subdomain" {
  description = "Subdomain für Supabase (z.B. supabase, api)"
  type        = string
  default     = "supabase"
}

# =============================================================================
# Supabase Variablen
# =============================================================================

variable "postgres_password" {
  description = "PostgreSQL Datenbank Passwort"
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "JWT Secret für Token-Signierung (min. 32 Zeichen)"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.jwt_secret) >= 32
    error_message = "jwt_secret muss mindestens 32 Zeichen lang sein."
  }
}

variable "anon_key" {
  description = "Supabase Anonymous API Key"
  type        = string
  sensitive   = true
}

variable "service_role_key" {
  description = "Supabase Service Role API Key"
  type        = string
  sensitive   = true
}

variable "dashboard_username" {
  description = "Supabase Studio Dashboard Benutzername"
  type        = string
  default     = "admin"
}

variable "dashboard_password" {
  description = "Supabase Studio Dashboard Passwort"
  type        = string
  sensitive   = true
}

variable "acme_email" {
  description = "E-Mail für Let's Encrypt Zertifikate"
  type        = string
}

variable "secret_key_base" {
  description = "Secret Key Base für Realtime/Supavisor (min. 64 Zeichen)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "vault_enc_key" {
  description = "Vault Encryption Key für Supavisor (32 Zeichen hex)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "logflare_api_key" {
  description = "Logflare API Key (Public/Ingest)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "logflare_private_key" {
  description = "Logflare Private Access Token (Query/Management)"
  type        = string
  sensitive   = true
  default     = ""
}

# =============================================================================
# Hetzner S3 Variablen
# =============================================================================

variable "s3_endpoint" {
  description = "Hetzner S3 Endpoint URL"
  type        = string

  validation {
    condition     = can(regex("^https://", var.s3_endpoint))
    error_message = "s3_endpoint muss eine HTTPS-URL sein (z.B. https://fsn1.your-objectstorage.com)."
  }
}

variable "s3_region" {
  description = "S3 Region"
  type        = string
  default     = "eu-central-1"
}

variable "s3_access_key" {
  description = "S3 Access Key"
  type        = string
  sensitive   = true
}

variable "s3_secret_key" {
  description = "S3 Secret Key"
  type        = string
  sensitive   = true
}

variable "s3_storage_bucket" {
  description = "S3 Bucket für Supabase Storage"
  type        = string
}

variable "s3_backup_bucket" {
  description = "S3 Bucket für Backups"
  type        = string
}

# =============================================================================
# Notification Variablen
# =============================================================================

variable "notification_urls" {
  description = "Shoutrrr Notification URLs (Telegram, Slack, etc.)"
  type        = string
  default     = ""
}

# =============================================================================
# Restore Variablen
# =============================================================================

variable "restore_from_backup" {
  description = "Ob ein Backup nach dem Deployment wiederhergestellt werden soll"
  type        = bool
  default     = false
}

variable "backup_date" {
  description = "Datum des Backups für Restore (Format: YYYY-MM-DD)"
  type        = string
  default     = ""
}

# =============================================================================
# Backup Encryption Variablen
# =============================================================================

variable "backup_encryption_key" {
  description = "GPG Passphrase für Backup-Verschlüsselung (optional, leer = keine Verschlüsselung)"
  type        = string
  default     = ""
  sensitive   = true
}
