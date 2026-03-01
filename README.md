# Supabase Self-Hosting auf Hetzner Cloud

Vollständig automatisiertes, wiederherstellbares Supabase Self-Hosting Setup auf Hetzner Cloud.

## Features

- **Terraform**: Automatisierte Infrastruktur (VM, Firewall, DNS)
- **Cloudflare**: DNS Records + Health Checks
- **Cloud-init**: Automatisches Server-Bootstrapping
- **Docker Compose**: Supabase + Portainer + Uptime Kuma
- **Caddy**: Reverse Proxy mit automatischen Let's Encrypt Zertifikaten
- **Automatische Backups**: docker-volume-backup → Cloudflare R2 (S3-kompatibel)
- **GPG-Verschlüsselung**: Optionale Backup-Verschlüsselung
- **Disaster Recovery**: Vollständige Wiederherstellung aus Backup
- **Monitoring**: Uptime Kuma + Cloudflare Health Checks
- **Notifications**: Telegram/Slack/Discord bei Backup-Fehlern

## Voraussetzungen

- [Terraform](https://www.terraform.io/downloads) >= 1.0
- [Hetzner Cloud Account](https://console.hetzner.cloud/)
- [Cloudflare Account](https://dash.cloudflare.com/) (kostenlos)
- Domain bei Cloudflare
- S3-kompatibler Storage (Cloudflare R2, Hetzner S3, etc.)
- Python3 + PyJWT (für Secret-Generierung)

## Kosten (ca.)

| Ressource | Test | Produktion |
|-----------|------|------------|
| Hetzner VM | CX22: ~4€/Mo | CPX31: ~15€/Mo |
| Cloudflare R2 (100GB) | ~1.50€/Mo | ~1.50€/Mo |
| Cloudflare | Kostenlos | Kostenlos |
| **Gesamt** | **~5.50€/Mo** | **~16.50€/Mo** |

## Schnellstart

### 1. Repository klonen

```bash
git clone https://github.com/your-username/supabase-hetzner.git
cd supabase-hetzner
```

### 2. Konfiguration erstellen

```bash
mkdir -p environments/dev
cp terraform/terraform.tfvars.example environments/dev/terraform.tfvars
```

Bearbeite `environments/dev/terraform.tfvars` und fülle alle Werte aus:

- `hcloud_token`: [Hetzner Cloud Console](https://console.hetzner.cloud/) → Project → Security → API Tokens
- `cloudflare_api_token`: [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) (DNS Edit Permission)
- `cloudflare_zone_id`: Cloudflare Dashboard → Domain → Overview → Zone ID
- `ssh_public_key`: Dein öffentlicher SSH Key
- `admin_ips`: Deine IP-Adresse für SSH-Zugang
- `s3_*`: S3 Storage Credentials (Cloudflare R2 oder Hetzner S3)

### 3. Deployment

```bash
./scripts/deploy.sh --env dev --init --apply
```

Das Script generiert automatisch Secrets und führt `terraform init` + `apply` aus.

### 4. Fertig!

Nach ~5-10 Minuten sind die Services erreichbar:

| Service | URL |
|---------|-----|
| Supabase Studio | `https://api.deine-domain.de` |
| Portainer | `https://portainer.api.deine-domain.de` |
| Uptime Kuma | `https://status.api.deine-domain.de` |

## Zugang

Nach dem Deployment:

| Service | URL | Authentifizierung |
|---------|-----|-------------------|
| Supabase Studio | `https://api.domain.de` | Dashboard Username/Password |
| Supabase REST API | `https://api.domain.de/rest/v1/` | Anon/Service Key |
| Supabase Auth | `https://api.domain.de/auth/v1/` | Anon/Service Key |
| Supabase Realtime | `https://api.domain.de/realtime/v1/` | Anon/Service Key |
| Supabase Storage | `https://api.domain.de/storage/v1/` | Anon/Service Key |
| Portainer | `https://portainer.api.domain.de` | Eigenes Setup |
| Uptime Kuma | `https://status.api.domain.de` | Eigenes Setup |

## Backups

### Automatische Backups

- **Zeitplan**: Täglich um 03:00 Uhr
- **Aufbewahrung**: 14 Tage
- **Ziel**: S3 Bucket (Cloudflare R2)
- **Inhalt**: PostgreSQL Dump (pg_dumpall) + .env Konfiguration
- **Verschlüsselung**: Optional via GPG

### Was wird gebackupt?

| Komponente | Backup-Methode | Speicherort |
|------------|----------------|-------------|
| PostgreSQL DB | pg_dumpall → tar.gz | S3 Bucket |
| Storage Files | - | Bereits in S3 (extern) |
| Konfiguration | .env Datei | S3 Bucket + Git |

### Manuelles Backup

```bash
# Via SSH auf dem Server
ssh ubuntu@SERVER_IP
docker exec backup /usr/local/bin/backup
```

### Backup-Verschlüsselung

Setze `backup_encryption_key` in `environments/<env>/terraform.tfvars`:

```hcl
backup_encryption_key = "dein-sicheres-passwort"
```

### Backup-Benachrichtigungen

Konfiguriere `notification_urls` in `environments/<env>/terraform.tfvars`:

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
ssh ubuntu@SERVER_IP
/opt/supabase/scripts/restore.sh --list
```

### Wiederherstellung

**Option 1: Bei Neudeployment**

```bash
./scripts/deploy.sh --env dev --apply --restore 2024-01-15
```

**Option 2: Auf bestehendem Server**

```bash
ssh ubuntu@SERVER_IP
/opt/supabase/scripts/restore.sh 2024-01-15
```

**Option 3: Neuestes Backup**

```bash
ssh ubuntu@SERVER_IP
/opt/supabase/scripts/restore.sh --latest
```

## Architektur

```
┌─────────────────────────────────────────────────────────────────┐
│                        Cloudflare                                │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │ DNS Records │  │Health Check │  │   Alerts    │              │
│  │  A + AAAA   │  └──────┬──────┘  └─────────────┘              │
│  │  + CNAMEs   │         │                                       │
│  └──────┬──────┘         │                                       │
└─────────┼────────────────┼──────────────────────────────────────┘
          │                │
          ▼                ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Hetzner Cloud VM                             │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                     Docker Compose                        │   │
│  │                                                           │   │
│  │  ┌─────────────────────────────────────────────────────┐ │   │
│  │  │              Caddy (HTTPS - Port 443)               │ │   │
│  │  │           Let's Encrypt Zertifikate                 │ │   │
│  │  └──────┬──────────────┬──────────────┬───────────────┘ │   │
│  │         │              │              │                  │   │
│  │         ▼              ▼              ▼                  │   │
│  │  ┌────────────┐ ┌───────────┐ ┌────────────┐            │   │
│  │  │    Kong    │ │ Portainer │ │Uptime Kuma │            │   │
│  │  │ (API GW)   │ │  (:9443)  │ │  (:3001)   │            │   │
│  │  └──────┬─────┘ └───────────┘ └────────────┘            │   │
│  │         │                                                │   │
│  │  ┌──────┴─────────────────────────────────────────────┐ │   │
│  │  │ Studio │ Auth │ REST │ Realtime │ Storage │ Funcs  │ │   │
│  │  └────────────────────────┬───────────────────────────┘ │   │
│  │                           │                              │   │
│  │  ┌────────────────────────┴───────────────────────────┐ │   │
│  │  │              PostgreSQL + Pooler                    │ │   │
│  │  └─────────────────────────────────────────────────────┘ │   │
│  │                                                           │   │
│  │  ┌─────────────────────────────────────────────────────┐ │   │
│  │  │           docker-volume-backup → S3                 │ │   │
│  │  └─────────────────────────────────────────────────────┘ │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Cloudflare R2 (S3)                            │
│  ┌─────────────────────┐    ┌─────────────────────┐             │
│  │  supabase-storage   │    │  supabase-backups   │             │
│  │    (User Files)     │    │   (DB + Config)     │             │
│  └─────────────────────┘    └─────────────────────┘             │
└─────────────────────────────────────────────────────────────────┘
```

## Firewall Regeln

| Port | Protokoll | Service | Zugriff |
|------|-----------|---------|---------|
| 22 | TCP | SSH | Nur Admin-IPs |
| 80 | TCP | HTTP | Alle (Let's Encrypt ACME) |
| 443 | TCP | HTTPS | Alle (Caddy → alle Services) |
| 443 | UDP | HTTP/3 (QUIC) | Alle |

## Sicherheit

- SSH nur mit Key-Authentifizierung
- Fail2ban aktiv (SSH Brute-Force Schutz)
- Hetzner Firewall + UFW
- Automatische Sicherheitsupdates (unattended-upgrades)
- PostgreSQL nicht öffentlich erreichbar
- Alle Services hinter Caddy Reverse Proxy
- Optionale GPG-Verschlüsselung für Backups

## Projektstruktur

```
supabase-hetzner/
├── terraform/                         # Terraform Code (keine Variablen-Werte!)
│   ├── main.tf                        # Hauptkonfiguration
│   ├── variables.tf                   # Variablen-Definitionen
│   ├── outputs.tf                     # Outputs
│   ├── providers.tf                   # Provider-Konfiguration
│   ├── hetzner.tf                     # Hetzner Ressourcen (VM, Firewall)
│   ├── cloudflare.tf                  # Cloudflare DNS
│   ├── terraform.tfvars.example       # Beispiel-Konfiguration
│   ├── backend.tfvars                 # S3 Backend für Terraform State
│   └── backend.tfvars.example         # Beispiel Backend-Konfiguration
├── environments/                      # Variablen pro Umgebung
│   ├── dev/
│   │   ├── terraform.tfvars           # Dev-Konfiguration
│   │   └── secrets.auto.tfvars        # Dev-Secrets (auto-generiert)
│   └── prod/
│       ├── terraform.tfvars           # Prod-Konfiguration
│       └── secrets.auto.tfvars        # Prod-Secrets (auto-generiert)
├── cloud-init/
│   ├── user-data.yaml.tpl            # Server-Bootstrapping Template
│   └── configs/
│       ├── Caddyfile                  # Caddy Reverse Proxy Config
│       ├── docker-compose.override.yml
│       ├── supabase.env.tpl           # Supabase Umgebungsvariablen
│       └── restore.sh                 # Server Restore Script
├── scripts/
│   ├── deploy.sh                      # Deployment-Script (Multi-Environment)
│   ├── generate-secrets.sh            # Secret-Generierung (JWT Keys etc.)
│   ├── test-backup.sh                 # Lokaler Backup-Test
│   └── test-deployment.sh             # Deployment-Verifizierung
└── README.md
```

## Troubleshooting

### SSL-Zertifikat wird nicht ausgestellt

```bash
# Caddy Logs prüfen
ssh ubuntu@SERVER_IP
docker logs caddy

# DNS prüfen
dig api.domain.de
dig portainer.api.domain.de
```

### Datenbank-Verbindung fehlgeschlagen

```bash
ssh ubuntu@SERVER_IP
cd /opt/supabase
docker compose logs db
docker compose exec db pg_isready -U postgres
```

### Backup fehlgeschlagen

```bash
ssh ubuntu@SERVER_IP
docker logs backup

# S3 Verbindung testen (lokal)
./scripts/test-backup.sh
```

### Services starten nicht

```bash
ssh ubuntu@SERVER_IP
cd /opt/supabase
docker compose ps
docker compose logs

# Einzelnen Service neustarten
docker compose restart caddy
```

### Cloud-init Logs prüfen

```bash
ssh ubuntu@SERVER_IP
cat /var/log/supabase-setup.log
cat /var/log/cloud-init-output.log
```

## Lizenz

MIT License - siehe [LICENSE](LICENSE)

## Beiträge

Pull Requests sind willkommen! Bitte erstelle zuerst ein Issue für größere Änderungen.
