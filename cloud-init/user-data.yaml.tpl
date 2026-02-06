#cloud-config
# =============================================================================
# Supabase Self-Hosting Cloud-init Konfiguration
# =============================================================================
# Diese Datei wird von Terraform gerendert und konfiguriert einen Ubuntu Server
# mit Supabase, Portainer, Uptime Kuma und automatischen Backups.
#
# Config-Dateien werden aus cloud-init/configs/ via Terraform eingebunden.
# =============================================================================

package_update: true
package_upgrade: true

packages:
  - docker.io
  - docker-compose-plugin
  - git
  - curl
  - jq
  - unzip
  - unattended-upgrades
  - fail2ban
  - ufw

# =============================================================================
# Konfigurationsdateien
# =============================================================================

write_files:
  # ---------------------------------------------------------------------------
  # Automatische Sicherheitsupdates
  # ---------------------------------------------------------------------------
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
      APT::Periodic::AutocleanInterval "7";

  # ---------------------------------------------------------------------------
  # Fail2ban Konfiguration
  # ---------------------------------------------------------------------------
  - path: /etc/fail2ban/jail.local
    content: |
      [sshd]
      enabled = true
      bantime = 3600
      findtime = 600
      maxretry = 3

  # ---------------------------------------------------------------------------
  # Supabase .env Datei (aus configs/supabase.env.tpl)
  # ---------------------------------------------------------------------------
  - path: /opt/supabase/.env
    permissions: '0600'
    content: |
${indent(6, supabase_env)}

  # ---------------------------------------------------------------------------
  # Kong Konfiguration (aus configs/kong.yml.tpl)
  # ---------------------------------------------------------------------------
  - path: /opt/supabase/volumes/api/kong.yml
    content: |
${indent(6, kong_config)}

  # ---------------------------------------------------------------------------
  # Docker Compose Override (aus configs/docker-compose.override.yml)
  # ---------------------------------------------------------------------------
  - path: /opt/supabase/docker-compose.override.yml
    content: |
${indent(6, docker_compose_override)}

  # ---------------------------------------------------------------------------
  # Caddyfile (aus configs/Caddyfile)
  # ---------------------------------------------------------------------------
  - path: /opt/supabase/caddy/Caddyfile
    content: |
${indent(6, caddyfile)}

  # ---------------------------------------------------------------------------
  # Restore Script (aus configs/restore.sh)
  # ---------------------------------------------------------------------------
  - path: /opt/supabase/scripts/restore.sh
    permissions: '0755'
    content: |
${indent(6, restore_script)}

# =============================================================================
# Ausführungsbefehle
# =============================================================================

runcmd:
  # ---------------------------------------------------------------------------
  # Setup Logging & Error Handling
  # ---------------------------------------------------------------------------
  - |
    exec > >(tee -a /var/log/supabase-setup.log) 2>&1
    echo "=== Supabase Setup started at $(date -Iseconds) ==="

  - |
    set -euo pipefail
    trap 'echo "ERROR at line $LINENO, exit code: $?" | tee -a /var/log/supabase-setup.log' ERR

  # ---------------------------------------------------------------------------
  # Docker Setup mit Retry
  # ---------------------------------------------------------------------------
  - |
    echo "Enabling Docker..."
    systemctl enable docker
    systemctl start docker
    for i in {1..30}; do
      docker info &>/dev/null && break
      echo "Waiting for Docker... ($i/30)"
      sleep 2
    done
    if ! docker info &>/dev/null; then
      echo "ERROR: Docker did not start!"
      exit 1
    fi
    echo "Docker ready."

  # Docker Gruppe für ubuntu User
  - usermod -aG docker ubuntu

  # ---------------------------------------------------------------------------
  # Verzeichnisse erstellen
  # ---------------------------------------------------------------------------
  - mkdir -p /opt/supabase/volumes/api
  - mkdir -p /opt/supabase/volumes/db/data
  - mkdir -p /opt/supabase/scripts
  - mkdir -p /opt/supabase/caddy

  # ---------------------------------------------------------------------------
  # AWS CLI für S3 Backups installieren (mit Retry)
  # ---------------------------------------------------------------------------
  - |
    echo "Installing AWS CLI..."
    for i in {1..3}; do
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip" && break
      echo "AWS CLI download failed, retry $i/3..."
      sleep 5
    done
    unzip -q /tmp/awscliv2.zip -d /tmp/
    /tmp/aws/install
    rm -rf /tmp/aws /tmp/awscliv2.zip
    echo "AWS CLI installed."

  # ---------------------------------------------------------------------------
  # Supabase Docker Setup klonen (mit Retry)
  # ---------------------------------------------------------------------------
  - |
    echo "Cloning Supabase repository..."
    for i in {1..3}; do
      git clone --depth 1 https://github.com/supabase/supabase /tmp/supabase-repo && break
      echo "Git clone failed, retry $i/3..."
      rm -rf /tmp/supabase-repo
      sleep 10
    done
    if [ ! -d "/tmp/supabase-repo" ]; then
      echo "ERROR: Failed to clone Supabase repository!"
      exit 1
    fi

  # Nur docker-compose.yml kopieren (nicht die .env)
  - cp /tmp/supabase-repo/docker/docker-compose.yml /opt/supabase/
  - cp -r /tmp/supabase-repo/docker/volumes /opt/supabase/

  # Unsere Kong Konfiguration überschreibt die Standard-Konfiguration
  # (wurde bereits via write_files nach /opt/supabase/volumes/api/kong.yml geschrieben)

  # Aufräumen
  - rm -rf /tmp/supabase-repo

  # ---------------------------------------------------------------------------
  # Firewall konfigurieren
  # ---------------------------------------------------------------------------
  - |
    echo "Configuring UFW firewall..."
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp     # SSH
    ufw allow 80/tcp     # HTTP (Let's Encrypt ACME)
    ufw allow 443/tcp    # HTTPS (Caddy - alle Services)
    ufw allow 443/udp    # HTTP/3 (QUIC)
    # Portainer und Uptime Kuma laufen über Caddy (Port 443)
    ufw --force enable
    echo "Firewall configured."

  # ---------------------------------------------------------------------------
  # Fail2ban aktivieren
  # ---------------------------------------------------------------------------
  - systemctl enable fail2ban
  - systemctl start fail2ban

  # ---------------------------------------------------------------------------
  # Docker Images pullen (mit Retry)
  # ---------------------------------------------------------------------------
  - |
    echo "Pulling Docker images..."
    cd /opt/supabase
    for i in {1..3}; do
      docker compose pull && break
      echo "Docker pull failed, retry $i/3..."
      sleep 15
    done

  # ---------------------------------------------------------------------------
  # Supabase starten
  # ---------------------------------------------------------------------------
  - |
    echo "Starting Supabase services..."
    cd /opt/supabase
    docker compose up -d

  # ---------------------------------------------------------------------------
  # Warten auf Services + Health Check
  # ---------------------------------------------------------------------------
  - |
    echo "Waiting for services to be healthy..."
    sleep 30
    cd /opt/supabase
    for i in {1..30}; do
      if docker compose ps | grep -q "healthy"; then
        echo "Services are starting up..."
      fi
      # Check if db is ready
      if docker compose exec -T db pg_isready -U postgres &>/dev/null; then
        echo "Database is ready."
        break
      fi
      echo "Waiting for database... ($i/30)"
      sleep 5
    done

  # ---------------------------------------------------------------------------
  # Optional: Restore von Backup
  # ---------------------------------------------------------------------------
%{ if restore_from_backup ~}
  - |
    echo "=== Preparing for restore from backup ==="
    sleep 30
    /opt/supabase/scripts/restore.sh "${backup_date}"
%{ endif ~}

  # ---------------------------------------------------------------------------
  # Final Status
  # ---------------------------------------------------------------------------
  - |
    echo "=== Supabase Setup completed at $(date -Iseconds) ==="
    echo ""
    echo "URLs (alle über Caddy mit SSL):"
    echo "  Supabase:    https://${domain}"
    echo "  Portainer:   https://portainer.${domain}"
    echo "  Uptime Kuma: https://status.${domain}"
    echo ""
    echo "Check status: docker compose ps"
    echo "Check logs: /var/log/supabase-setup.log"
