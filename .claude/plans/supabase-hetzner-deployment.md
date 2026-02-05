# Supabase Self-Hosting auf Hetzner Cloud - Implementierungsplan

## Übersicht

Vollständig automatisiertes, wiederherstellbares Supabase Self-Hosting Setup auf Hetzner Cloud mit Terraform, Cloud-init, Docker Compose und automatischen Backups.

## Status: ✅ Implementierung abgeschlossen

---

## Erledigte Aufgaben

### 1. Repository-Struktur ✅
- [x] Verzeichnisstruktur erstellt (terraform/, cloud-init/, docker/, scripts/)
- [x] Reference-Dokumentation geklont (docker-volume-backup, shoutrrr, terraform-provider-hcloud, terraform-provider-cloudflare, supabase, supabase-letsencrypt)

### 2. Terraform Konfiguration ✅
- [x] `terraform/providers.tf` - Hetzner + Cloudflare Provider
- [x] `terraform/variables.tf` - Alle Variablen definiert
- [x] `terraform/hetzner.tf` - VM, Firewall, SSH Key
- [x] `terraform/cloudflare.tf` - DNS Record + Health Check
- [x] `terraform/outputs.tf` - Server IP, URLs, SSH Command
- [x] `terraform/terraform.tfvars.example` - Beispielkonfiguration

### 3. Cloud-init Template ✅
- [x] `cloud-init/user-data.yaml.tpl` - Vollständiges Bootstrap-Template
  - Package Installation (docker, fail2ban, unattended-upgrades)
  - Supabase .env Generierung
  - Kong ACME Konfiguration mit Redis
  - Docker Compose Modifikationen
  - UFW Firewall Rules
  - Restore-Skript Integration

### 4. Docker Konfiguration ✅
- [x] `docker/.env.example` - Beispiel-Umgebungsvariablen

### 5. Shell-Skripte ✅
- [x] `scripts/generate-secrets.sh` - JWT Keys, Passwörter generieren
- [x] `scripts/deploy.sh` - Vollautomatisiertes Deployment
- [x] `scripts/restore.sh` - Disaster Recovery
- [x] `scripts/backup-now.sh` - Manuelles Backup

### 6. Dokumentation ✅
- [x] `.gitignore` - Secrets, Terraform State, etc.
- [x] `README.md` - Vollständige Dokumentation

---

## Ausstehende Validierung

### Lokale Validierung (Terraform nicht installiert)
- [ ] `terraform init` - Provider initialisieren
- [ ] `terraform validate` - Syntax prüfen
- [ ] `terraform plan` - Plan erstellen

### Deployment-Test
- [ ] Secrets generieren
- [ ] terraform.tfvars ausfüllen
- [ ] Deployment auf Hetzner
- [ ] SSL-Zertifikat prüfen
- [ ] Backup-Funktion testen
- [ ] Restore-Funktion testen

---

## Architektur

```
Cloudflare (DNS + Health Check)
         │
         ▼
Hetzner Cloud VM (Ubuntu 24.04)
├── Docker Compose
│   ├── Kong (HTTPS + Let's Encrypt ACME)
│   ├── Supabase Services (Studio, Auth, REST, Realtime, Storage, etc.)
│   ├── PostgreSQL + Pooler
│   ├── Portainer (Container Management)
│   ├── Uptime Kuma (Monitoring)
│   └── Backup (docker-volume-backup)
│
└── Hetzner S3
    ├── supabase-storage (User Files)
    └── supabase-backups (DB + Volumes)
```

---

## Dateien

```
supabase-hetzner/
├── terraform/
│   ├── providers.tf          ✅
│   ├── variables.tf          ✅
│   ├── hetzner.tf            ✅
│   ├── cloudflare.tf         ✅
│   ├── outputs.tf            ✅
│   └── terraform.tfvars.example ✅
├── cloud-init/
│   └── user-data.yaml.tpl    ✅
├── docker/
│   └── .env.example          ✅
├── scripts/
│   ├── deploy.sh             ✅
│   ├── generate-secrets.sh   ✅
│   ├── restore.sh            ✅
│   └── backup-now.sh         ✅
├── .gitignore                ✅
└── README.md                 ✅
```

---

## Nächste Schritte für Benutzer

1. Terraform installieren: https://www.terraform.io/downloads
2. `cp terraform/terraform.tfvars.example terraform/terraform.tfvars`
3. terraform.tfvars ausfüllen (Hetzner Token, Cloudflare API, etc.)
4. `./scripts/deploy.sh --init --apply`
5. Warten bis Server bereit (~5-10 Min)
6. Supabase unter https://subdomain.domain.de aufrufen
