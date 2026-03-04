#!/bin/bash
# =============================================================================
# Edge Function Secrets Deployment
# =============================================================================
# Deployt App-spezifische Secrets (.env.functions) auf den Supabase-Server
# und startet den Functions-Container mit den neuen Env-Vars neu.
#
# Verwendung:
#   ./scripts/deploy-secrets.sh --env dev
#   ./scripts/deploy-secrets.sh --env prod
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_DIR/terraform"
ENVIRONMENTS_DIR="$PROJECT_DIR/environments"

ACTIVE_ENV=""
ENV_DIR=""

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=no"

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${BLUE}==============================================================================${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}==============================================================================${NC}"
    echo ""
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_info()    { echo -e "${CYAN}ℹ $1${NC}"; }

# =============================================================================
# Multi-Environment
# =============================================================================

resolve_environment() {
    if [ -z "$ACTIVE_ENV" ]; then
        if [ -d "$ENVIRONMENTS_DIR/prod" ]; then
            ACTIVE_ENV="prod"
        elif [ -d "$ENVIRONMENTS_DIR/dev" ]; then
            ACTIVE_ENV="dev"
        else
            print_error "Keine Umgebung gefunden. Verwende --env dev|prod"
            exit 1
        fi
    fi

    ENV_DIR="$ENVIRONMENTS_DIR/$ACTIVE_ENV"
    if [ ! -d "$ENV_DIR" ]; then
        print_error "Umgebung '$ACTIVE_ENV' nicht gefunden: $ENV_DIR"
        exit 1
    fi
}

select_workspace() {
    if [ -n "$ACTIVE_ENV" ]; then
        cd "$TERRAFORM_DIR"
        terraform workspace select "$ACTIVE_ENV" 2>/dev/null || \
            terraform workspace new "$ACTIVE_ENV"
    fi
}

get_server_ip() {
    cd "$TERRAFORM_DIR"
    select_workspace
    terraform output -raw server_ip 2>/dev/null || echo ""
}

# =============================================================================
# Verwendung
# =============================================================================

usage() {
    cat << EOF
${BLUE}Edge Function Secrets Deployment${NC}

Verwendung: $0 --env <dev|prod>

Deployt ${CYAN}environments/<env>/.env.functions${NC} auf den Supabase-Server
und startet den Functions-Container mit den neuen Env-Vars neu.

Optionen:
  ${GREEN}--env ENV${NC}    Wählt die Umgebung (dev, prod, etc.)
  ${GREEN}--help${NC}       Zeigt diese Hilfe

Erstmalige Einrichtung:
  ${CYAN}cp .env.functions.example environments/dev/.env.functions${NC}
  # Werte eintragen, dann:
  ${CYAN}$0 --env dev${NC}

EOF
    exit 0
}

# =============================================================================
# Argument Parsing
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --env)
            if [[ $# -gt 1 && ! "$2" =~ ^-- ]]; then
                ACTIVE_ENV="$2"
                shift 2
            else
                print_error "--env benötigt einen Wert (dev, prod, ...)"
                exit 1
            fi
            ;;
        --help|-h)
            usage
            ;;
        *)
            print_error "Unbekannte Option: $1"
            echo ""
            usage
            ;;
    esac
done

# =============================================================================
# Ausführung
# =============================================================================

print_header "Edge Function Secrets deployen"

resolve_environment
print_info "Umgebung: $ACTIVE_ENV"

# Prüfe ob .env.functions existiert
ENV_FUNCTIONS_FILE="$ENV_DIR/.env.functions"

if [ ! -f "$ENV_FUNCTIONS_FILE" ]; then
    print_error ".env.functions nicht gefunden: $ENV_FUNCTIONS_FILE"
    echo ""
    echo "Erstelle die Datei:"
    echo "  cp .env.functions.example $ENV_DIR/.env.functions"
    echo ""
    echo "Fülle die Werte aus und starte erneut:"
    echo "  $0 --env $ACTIVE_ENV"
    exit 1
fi

# Prüfe ob Datei leer ist
if [ ! -s "$ENV_FUNCTIONS_FILE" ]; then
    print_warning ".env.functions ist leer: $ENV_FUNCTIONS_FILE"
fi

# Server IP holen
server_ip=$(get_server_ip)

if [ -z "$server_ip" ]; then
    print_error "Keine Server IP gefunden - ist die Infrastruktur deployed?"
    print_info "Deploye zuerst: ./scripts/deploy.sh --env $ACTIVE_ENV --init --apply"
    exit 1
fi

print_info "Server: $server_ip"

# Prüfe SSH-Verbindung
if ! ssh $SSH_OPTS -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR \
        "ubuntu@$server_ip" "exit 0" 2>/dev/null; then
    print_error "SSH-Verbindung zu $server_ip fehlgeschlagen"
    exit 1
fi

# .env.functions auf Server kopieren
print_info "Kopiere .env.functions auf Server..."
scp $SSH_OPTS "$ENV_FUNCTIONS_FILE" "ubuntu@$server_ip:/tmp/.env.functions"
ssh $SSH_OPTS "ubuntu@$server_ip" "sudo mv /tmp/.env.functions /opt/supabase/.env.functions && sudo chown root:root /opt/supabase/.env.functions && sudo chmod 600 /opt/supabase/.env.functions"
print_success ".env.functions kopiert"

# Functions-Container neu starten
print_info "Starte Functions-Container neu..."
ssh $SSH_OPTS "ubuntu@$server_ip" "cd /opt/supabase && sudo docker compose up -d functions"
print_success "Functions-Container neu gestartet"

echo ""
echo -e "${GREEN}Edge Function Secrets für '$ACTIVE_ENV' erfolgreich deployed!${NC}"
