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
  # System Setup
  # ---------------------------------------------------------------------------
  - echo "=== Starting Supabase Setup ==="

  # Docker aktivieren
  - systemctl enable docker
  - systemctl start docker

  # Docker Gruppe für ubuntu User
  - usermod -aG docker ubuntu

  # ---------------------------------------------------------------------------
  # Verzeichnisse erstellen
  # ---------------------------------------------------------------------------
  - mkdir -p /opt/supabase/volumes/api
  - mkdir -p /opt/supabase/volumes/db/data
  - mkdir -p /opt/supabase/scripts

  # ---------------------------------------------------------------------------
  # AWS CLI für S3 Backups installieren
  # ---------------------------------------------------------------------------
  - curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
  - unzip -q /tmp/awscliv2.zip -d /tmp/
  - /tmp/aws/install
  - rm -rf /tmp/aws /tmp/awscliv2.zip

  # ---------------------------------------------------------------------------
  # Supabase Docker Setup klonen
  # ---------------------------------------------------------------------------
  - git clone --depth 1 https://github.com/supabase/supabase /tmp/supabase-repo

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
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow 22/tcp    # SSH
  - ufw allow 80/tcp    # HTTP (Let's Encrypt ACME)
  - ufw allow 443/tcp   # HTTPS (Supabase)
  - ufw allow 9443/tcp  # Portainer
  - ufw allow 3001/tcp  # Uptime Kuma
  - ufw --force enable

  # ---------------------------------------------------------------------------
  # Fail2ban aktivieren
  # ---------------------------------------------------------------------------
  - systemctl enable fail2ban
  - systemctl start fail2ban

  # ---------------------------------------------------------------------------
  # Supabase starten
  # ---------------------------------------------------------------------------
  - cd /opt/supabase && docker compose pull
  - cd /opt/supabase && docker compose up -d

  # ---------------------------------------------------------------------------
  # Optional: Restore von Backup
  # ---------------------------------------------------------------------------
%{ if restore_from_backup ~}
  - echo "=== Waiting for services to start before restore ==="
  - sleep 60
  - /opt/supabase/scripts/restore.sh "${backup_date}"
%{ endif ~}

  # ---------------------------------------------------------------------------
  # Fertig
  # ---------------------------------------------------------------------------
  - echo "=== Supabase Setup Completed ==="
  - echo "Dashboard: https://${domain}"
  - echo "Portainer: https://${domain}:9443"
  - echo "Uptime Kuma: http://${domain}:3001"
