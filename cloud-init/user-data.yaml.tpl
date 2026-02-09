#cloud-config
# Supabase Self-Hosting Cloud-init Konfiguration

users:
  - default
  - name: ubuntu
    groups: [sudo, docker]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_public_key}

package_update: true
package_upgrade: true

packages:
  - docker.io
  - docker-compose-v2
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
    encoding: gz+b64
    content: ${supabase_env}

  # ---------------------------------------------------------------------------
  # Docker Compose Override (aus configs/docker-compose.override.yml)
  # ---------------------------------------------------------------------------
  - path: /opt/supabase/docker-compose.override.yml
    encoding: gz+b64
    content: ${docker_compose_override}

  # ---------------------------------------------------------------------------
  # Caddyfile (aus configs/Caddyfile)
  # ---------------------------------------------------------------------------
  - path: /opt/supabase/caddy/Caddyfile
    encoding: gz+b64
    content: ${caddyfile}

  # ---------------------------------------------------------------------------
  # Restore Script (aus configs/restore.sh)
  # ---------------------------------------------------------------------------
  - path: /opt/supabase/scripts/restore.sh
    permissions: '0755'
    encoding: gz+b64
    content: ${restore_script}

# =============================================================================
# Ausführungsbefehle
# =============================================================================

runcmd:
  # ---------------------------------------------------------------------------
  # Setup Logging
  # ---------------------------------------------------------------------------
  - echo "=== Supabase Setup started at $(date -Iseconds) ===" | tee -a /var/log/supabase-setup.log

  # ---------------------------------------------------------------------------
  # Docker Setup
  # ---------------------------------------------------------------------------
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker ubuntu

  # ---------------------------------------------------------------------------
  # Verzeichnisse erstellen
  # ---------------------------------------------------------------------------
  - mkdir -p /opt/supabase/volumes/api
  - mkdir -p /opt/supabase/volumes/db/data
  - mkdir -p /opt/supabase/scripts
  - mkdir -p /opt/supabase/caddy

  # ---------------------------------------------------------------------------
  # AWS CLI für S3 Backups installieren
  # ---------------------------------------------------------------------------
  - |
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
    unzip -q /tmp/awscliv2.zip -d /tmp/
    /tmp/aws/install
    rm -rf /tmp/aws /tmp/awscliv2.zip

  # ---------------------------------------------------------------------------
  # Supabase Docker Setup klonen
  # ---------------------------------------------------------------------------
  - git clone --depth 1 https://github.com/supabase/supabase /tmp/supabase-repo
  - cp /tmp/supabase-repo/docker/docker-compose.yml /opt/supabase/
  - cp -r /tmp/supabase-repo/docker/volumes /opt/supabase/
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
    # Portainer läuft über Caddy (Port 443)
    ufw --force enable
    echo "Firewall configured."

  # ---------------------------------------------------------------------------
  # Fail2ban aktivieren
  # ---------------------------------------------------------------------------
  - systemctl enable fail2ban
  - systemctl start fail2ban

  # ---------------------------------------------------------------------------
  # Portainer Admin-Passwort setzen (aus .env DASHBOARD_PASSWORD)
  # ---------------------------------------------------------------------------
  - |
    cd /opt/supabase
    grep -oP '^DASHBOARD_PASSWORD=\K.*' .env > /opt/supabase/portainer_password
    chmod 600 /opt/supabase/portainer_password

  # ---------------------------------------------------------------------------
  # Docker Images pullen und Supabase starten
  # ---------------------------------------------------------------------------
  - |
    cd /opt/supabase
    chown ubuntu:ubuntu /opt/supabase/.env
    docker compose pull
    docker compose up -d

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
    echo ""
    echo "Check status: docker compose ps"
    echo "Check logs: /var/log/supabase-setup.log"
