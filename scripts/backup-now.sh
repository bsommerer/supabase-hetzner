#!/bin/bash
# =============================================================================
# Manuelles Backup Script
# =============================================================================
# Löst ein sofortiges Backup aus.
#
# Verwendung:
#   ./scripts/backup-now.sh [--local | --remote]
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Farben
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

MODE="${1:---local}"

case "$MODE" in
    --local)
        # Lokales Backup (wenn lokal auf dem Server ausgeführt)
        echo -e "${BLUE}Starte lokales Backup...${NC}"

        if [ -f /opt/supabase/.env ]; then
            cd /opt/supabase
            docker exec backup /bin/sh -c '/usr/local/bin/backup'
            echo -e "${GREEN}✓ Backup gestartet${NC}"
            echo ""
            echo "Prüfe Status mit: docker logs -f backup"
        else
            echo -e "${RED}Nicht auf Supabase Server - verwende --remote${NC}"
            exit 1
        fi
        ;;

    --remote)
        # Remote Backup (via SSH)
        echo -e "${BLUE}Starte Remote Backup...${NC}"

        cd "$PROJECT_DIR/terraform"

        if ! terraform state list &> /dev/null; then
            echo -e "${RED}Keine Terraform State gefunden${NC}"
            exit 1
        fi

        SERVER_IP=$(terraform output -raw server_ip 2>/dev/null)

        if [ -z "$SERVER_IP" ]; then
            echo -e "${RED}Keine Server IP gefunden${NC}"
            exit 1
        fi

        echo "Server: $SERVER_IP"
        ssh "ubuntu@$SERVER_IP" "docker exec backup /bin/sh -c '/usr/local/bin/backup'"

        echo -e "${GREEN}✓ Backup gestartet auf $SERVER_IP${NC}"
        echo ""
        echo "Prüfe Status mit: ssh ubuntu@$SERVER_IP 'docker logs -f backup'"
        ;;

    --help|-h)
        echo "Verwendung: $0 [--local | --remote]"
        echo ""
        echo "  --local   Backup lokal ausführen (auf dem Server)"
        echo "  --remote  Backup via SSH ausführen (von lokal)"
        exit 0
        ;;

    *)
        echo -e "${RED}Unbekannte Option: $MODE${NC}"
        echo "Verwendung: $0 [--local | --remote]"
        exit 1
        ;;
esac
