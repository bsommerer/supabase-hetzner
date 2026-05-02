#!/bin/bash
# =============================================================================
# SSH Key Sync
# =============================================================================
# Schreibt die in terraform.tfvars gepflegten SSH Public Keys auf den
# laufenden Server. Cloud-init läuft nur beim First-Boot — dieses Script
# ist der Update-Pfad für bestehende Server.
#
# Verhalten: ersetzt ~ubuntu/.ssh/authorized_keys atomar, behält ein Backup
# als authorized_keys.bak. Bricht ab, wenn der lokale Key nicht in der Liste
# ist (Lockout-Schutz).
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Werte aus Terraform holen
# -----------------------------------------------------------------------------

if ! command -v terraform &>/dev/null; then
    echo -e "${RED}terraform nicht gefunden${NC}" >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo -e "${RED}jq nicht gefunden${NC}" >&2
    exit 1
fi

server_ip=$(terraform -chdir=terraform output -raw server_ip 2>/dev/null || true)
keys_json=$(terraform -chdir=terraform output -json ssh_public_keys 2>/dev/null || true)

if [ -z "$server_ip" ]; then
    echo -e "${RED}terraform output server_ip ist leer — terraform init/apply gelaufen?${NC}" >&2
    exit 1
fi

if [ -z "$keys_json" ] || [ "$keys_json" = "null" ]; then
    echo -e "${RED}terraform output ssh_public_keys ist leer${NC}" >&2
    exit 1
fi

mapfile -t keys < <(echo "$keys_json" | jq -r '.[]')

if [ "${#keys[@]}" -eq 0 ]; then
    echo -e "${RED}Leere Key-Liste — würde dich aussperren. Abbruch.${NC}" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Lockout-Check: lokaler Key muss in der Liste sein
# -----------------------------------------------------------------------------

local_key=""
for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
    [ -f "$f" ] && local_key=$(awk '{print $1, $2}' "$f") && break
done

if [ -n "$local_key" ]; then
    found=0
    for k in "${keys[@]}"; do
        if [ "$(echo "$k" | awk '{print $1, $2}')" = "$local_key" ]; then
            found=1
            break
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo -e "${YELLOW}WARNUNG: dein lokaler Public Key ist nicht in ssh_public_keys.${NC}" >&2
        echo -e "${YELLOW}Nach dem Sync kommst du nicht mehr per SSH rein.${NC}" >&2
        read -r -p "Trotzdem fortfahren? [y/N] " ans
        [ "${ans:-N}" = "y" ] || { echo "Abbruch."; exit 1; }
    fi
fi

# -----------------------------------------------------------------------------
# Sync
# -----------------------------------------------------------------------------

echo -e "${GREEN}Sync ${#keys[@]} Keys → ubuntu@${server_ip}${NC}"
for k in "${keys[@]}"; do echo "  - $(echo "$k" | awk '{print $NF}')"; done

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "${keys[@]}" > "$tmp"

scp -q "$tmp" "ubuntu@${server_ip}:/tmp/authorized_keys.new"
ssh "ubuntu@${server_ip}" 'set -e
mkdir -p ~/.ssh
chmod 700 ~/.ssh
[ -f ~/.ssh/authorized_keys ] && cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak
chmod 600 /tmp/authorized_keys.new
mv /tmp/authorized_keys.new ~/.ssh/authorized_keys
echo "OK: $(wc -l < ~/.ssh/authorized_keys) Keys aktiv (Backup: ~/.ssh/authorized_keys.bak)"'
