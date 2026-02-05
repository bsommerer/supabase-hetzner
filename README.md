# Supabase Self-Hosting auf Hetzner Cloud

Vollständig automatisiertes, wiederherstellbares Supabase Self-Hosting Setup auf Hetzner Cloud.

## Features

- **Terraform**: Automatisierte Infrastruktur (VM, Firewall, DNS)
- **Cloudflare**: DNS Records + Health Checks
- **Cloud-init**: Automatisches Server-Bootstrapping
- **Docker Compose**: Supabase + Portainer + Uptime Kuma
- **Let's Encrypt**: Automatische SSL-Zertifikate via Kong ACME
- **Automatische Backups**: docker-volume-backup → Hetzner S3
- **Disaster Recovery**: Vollständige Wiederherstellung aus Backup
- **Monitoring**: Uptime Kuma + Cloudflare Health Checks
- **Notifications**: Telegram/Slack/Discord bei Backup-Fehlern

## Voraussetzungen

- [Terraform](https://www.terraform.io/downloads) >= 1.0
- [Hetzner Cloud Account](https://console.hetzner.cloud/)
- [Cloudflare Account](https://dash.cloudflare.com/) (kostenlos)
- Domain bei Cloudflare
- Hetzner S3 Bucket (für Backups & Storage)
- OpenSSL & Python3 (für Secret-Generierung)

## Kosten (ca.)

| Ressource | Test | Produktion |
|-----------|------|------------|
| Hetzner VM | CX22: ~4€/Mo | CPX31: ~15€/Mo |
| Hetzner S3 (100GB) | ~2.50€/Mo | ~2.50€/Mo |
| Cloudflare | Kostenlos | Kostenlos |
| **Gesamt** | **~6.50€/Mo** | **~17.50€/Mo** |

## Schnellstart

### 1. Repository klonen

```bash
git clone https://github.com/your-username/supabase-hetzner.git
cd supabase-hetzner
```

### 2. Konfiguration erstellen

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Bearbeite `terraform/terraform.tfvars` und fülle alle Werte aus:

- `hcloud_token`: [Hetzner Cloud Console](https://console.hetzner.cloud/) → Project → Security → API Tokens
- `cloudflare_api_token`: [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) (DNS Edit Permission)
- `cloudflare_zone_id`: Cloudflare Dashboard → Domain → Overview → Zone ID
- `ssh_public_key`: Dein öffentlicher SSH Key
- `admin_ips`: Deine IP-Adresse für Admin-Zugang
- `s3_*`: Hetzner Object Storage Credentials

### 3. Deployment

```bash
# Secrets generieren und Terraform initialisieren
./scripts/deploy.sh --init

# Infrastruktur erstellen
./scripts/deploy.sh --apply
```

### 4. Fertig!

Nach ~5-10 Minuten ist Supabase unter `https://supabase.deine-domain.de` erreichbar.

## Deployment Skript

```bash
# Hilfe anzeigen
./scripts/deploy.sh --help

# Erstmaliges Deployment
./scripts/deploy.sh --init --apply

# Nur Plan anzeigen
./scripts/deploy.sh --plan

# Status prüfen
./scripts/deploy.sh --status

# SSH Verbindung
./scripts/deploy.sh --ssh

# Logs anzeigen
./scripts/deploy.sh --logs          # Alle Logs
./scripts/deploy.sh --logs kong     # Nur Kong Logs

# Manuelles Backup
./scripts/deploy.sh --backup-now

# Deployment mit Restore
./scripts/deploy.sh --apply --restore 2024-01-15

# Infrastruktur zerstören
./scripts/deploy.sh --destroy
```

## Zugang

Nach dem Deployment:

| Service | URL | Anmerkung |
|---------|-----|-----------|
| Supabase Studio | `https://supabase.domain.de` | Dashboard Username/Password |
| Supabase API | `https://supabase.domain.de/rest/v1/` | Anon/Service Key |
| Portainer | `https://supabase.domain.de:9443` | Nur von Admin-IPs |
| Uptime Kuma | `http://supabase.domain.de:3001` | Nur von Admin-IPs |

## Backups

### Automatische Backups

- **Zeitplan**: Täglich um 03:00 Uhr
- **Aufbewahrung**: 14 Tage
- **Ziel**: Hetzner S3 Bucket
- **Inhalt**: PostgreSQL Dump + Docker Volumes

### Manuelles Backup

```bash
./scripts/deploy.sh --backup-now
```

### Backup-Benachrichtigungen

Konfiguriere `notification_urls` in `terraform.tfvars`:

```hcl
# Telegram
notification_urls = "telegram://BOT_TOKEN@telegram?chats=CHAT_ID"

# Slack
notification_urls = "slack://hook:WEBHOOK_ID@webhook"

# Discord
notification_urls = "discord://TOKEN@WEBHOOK_ID"
```

## Disaster Recovery

### Verfügbare Backups anzeigen

```bash
./scripts/restore.sh --list
```

### Wiederherstellung

**Option 1: Bei Neudeployment**

```bash
./scripts/deploy.sh --apply --restore 2024-01-15
```

**Option 2: Auf bestehendem Server**

```bash
ssh ubuntu@SERVER_IP
/opt/supabase/scripts/restore.sh 2024-01-15
```

**Option 3: Neuestes Backup**

```bash
./scripts/restore.sh --latest
```

## Architektur

```
┌─────────────────────────────────────────────────────────────────┐
│                        Cloudflare                                │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │ DNS Record  │  │Health Check │  │   Alerts    │              │
│  └──────┬──────┘  └──────┬──────┘  └─────────────┘              │
└─────────┼────────────────┼──────────────────────────────────────┘
          │                │
          ▼                ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Hetzner Cloud VM                             │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                     Docker Compose                        │   │
│  │  ┌─────────────────────────────────────────────────────┐ │   │
│  │  │                    Kong (HTTPS)                      │ │   │
│  │  │              + Let's Encrypt ACME                    │ │   │
│  │  └────────────────────────┬────────────────────────────┘ │   │
│  │                           │                               │   │
│  │  ┌────────┐ ┌────────┐ ┌─┴──────┐ ┌────────┐ ┌────────┐ │   │
│  │  │ Studio │ │  Auth  │ │  REST  │ │Realtime│ │Storage │ │   │
│  │  └────────┘ └────────┘ └────────┘ └────────┘ └────┬───┘ │   │
│  │                           │                        │      │   │
│  │  ┌────────────────────────┴────────────────────────┼───┐ │   │
│  │  │              PostgreSQL + Pooler                │   │ │   │
│  │  └─────────────────────────────────────────────────┘   │ │   │
│  │                                                    │   │ │   │
│  │  ┌───────────┐  ┌────────────┐  ┌───────────────┐ │   │ │   │
│  │  │ Portainer │  │Uptime Kuma │  │    Backup     │─┼───┼─┼─┐ │
│  │  └───────────┘  └────────────┘  └───────────────┘ │   │ │ │ │
│  └───────────────────────────────────────────────────┼───┼─┘ │ │
└──────────────────────────────────────────────────────┼───┼───┼─┘
                                                       │   │   │
                                                       ▼   ▼   ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Hetzner S3                                  │
│  ┌─────────────────────┐    ┌─────────────────────┐             │
│  │  supabase-storage   │    │  supabase-backups   │             │
│  │    (User Files)     │    │   (DB + Volumes)    │             │
│  └─────────────────────┘    └─────────────────────┘             │
└─────────────────────────────────────────────────────────────────┘
```

## Firewall Regeln

| Port | Service | Zugriff |
|------|---------|---------|
| 22 | SSH | Nur Admin-IPs |
| 80 | HTTP | Alle (Let's Encrypt ACME) |
| 443 | HTTPS | Alle (Supabase API) |
| 9443 | Portainer | Nur Admin-IPs |
| 3001 | Uptime Kuma | Nur Admin-IPs |

## Sicherheit

- SSH nur mit Key-Authentifizierung
- Fail2ban aktiv (SSH Brute-Force Schutz)
- Hetzner Firewall + UFW
- Automatische Sicherheitsupdates (unattended-upgrades)
- PostgreSQL nicht öffentlich erreichbar
- Admin-Tools nur von konfigurierten IPs

## Dateistruktur

```
supabase-hetzner/
├── terraform/
│   ├── main.tf                  # Hauptkonfiguration
│   ├── variables.tf             # Variablen-Definitionen
│   ├── outputs.tf               # Outputs
│   ├── providers.tf             # Provider-Konfiguration
│   ├── hetzner.tf               # Hetzner Ressourcen
│   ├── cloudflare.tf            # Cloudflare DNS + Health
│   └── terraform.tfvars.example # Beispiel-Konfiguration
├── cloud-init/
│   └── user-data.yaml.tpl       # Server-Bootstrapping
├── docker/
│   └── .env.example             # Docker Umgebungsvariablen
├── scripts/
│   ├── deploy.sh                # Deployment-Automatisierung
│   ├── generate-secrets.sh      # Secret-Generierung
│   ├── restore.sh               # Disaster Recovery
│   └── backup-now.sh            # Manuelles Backup
└── README.md
```

## Troubleshooting

### SSL-Zertifikat wird nicht ausgestellt

```bash
# Kong Logs prüfen
./scripts/deploy.sh --logs kong

# ACME Challenge prüfen
curl -v http://supabase.domain.de/.well-known/acme-challenge/test
```

### Datenbank-Verbindung fehlgeschlagen

```bash
# PostgreSQL Status prüfen
./scripts/deploy.sh --ssh
docker compose logs db
```

### Backup fehlgeschlagen

```bash
# Backup Logs prüfen
./scripts/deploy.sh --logs backup

# S3 Verbindung testen
aws --endpoint-url $S3_ENDPOINT s3 ls s3://$S3_BACKUP_BUCKET/
```

### Services starten nicht

```bash
# Alle Services prüfen
./scripts/deploy.sh --status

# Einzelnen Service neustarten
./scripts/deploy.sh --ssh
docker compose restart kong
```

## Lizenz

MIT License - siehe [LICENSE](LICENSE)

## Beiträge

Pull Requests sind willkommen! Bitte erstelle zuerst ein Issue für größere Änderungen.
