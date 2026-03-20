#!/bin/bash
# =============================================================================
# Supabase Secrets Generator
# =============================================================================
# Generiert alle benötigten Secrets für Supabase und schreibt sie in
# secrets.auto.tfvars für Terraform.
#
# Verwendung:
#   ./scripts/generate-secrets.sh [OUTPUT_FILE]
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_FILE="${1:-$PROJECT_DIR/terraform/secrets.auto.tfvars}"

# Python Command (wird in check_requirements gesetzt)
PYTHON_CMD=""
PIP_CMD=""

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}==============================================================================${NC}"
echo -e "${BLUE} Supabase Secrets Generator${NC}"
echo -e "${BLUE}==============================================================================${NC}"
echo ""

# Prüfe Voraussetzungen
check_requirements() {
    local missing=()

    if ! command -v openssl &> /dev/null; then
        missing+=("openssl")
    fi

    # Python kann python3 oder python heißen (Windows)
    if command -v python3 &> /dev/null; then
        PYTHON_CMD="python3"
        PIP_CMD="pip3"
    elif command -v python &> /dev/null; then
        PYTHON_CMD="python"
        PIP_CMD="pip"
    else
        missing+=("python3/python")
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${RED}Fehler: Folgende Programme fehlen: ${missing[*]}${NC}"
        echo ""
        echo "Installation:"
        echo "  Ubuntu/Debian: sudo apt install openssl python3 python3-pip"
        echo "  macOS: brew install openssl python3"
        exit 1
    fi

    # Prüfe ob PyJWT installiert ist
    if ! $PYTHON_CMD -c "import jwt" 2>/dev/null; then
        echo -e "${YELLOW}PyJWT wird installiert...${NC}"
        $PIP_CMD install --quiet PyJWT
    fi

    echo -e "${GREEN}✓ Alle Voraussetzungen erfüllt${NC}"
}

# Generiere zufälligen String (nur alphanumerisch)
generate_alphanum() {
    local length=${1:-32}
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

# Generiere Base64 String
generate_base64() {
    local length=${1:-48}
    openssl rand -base64 "$length"
}

# Generiere Hex String
generate_hex() {
    local length=${1:-16}
    openssl rand -hex "$length"
}

# Generiere JWT Token
generate_jwt() {
    local role=$1
    local jwt_secret=$2

    $PYTHON_CMD << PYTHON
import jwt
import time

payload = {
    'role': '$role',
    'iss': 'supabase',
    'iat': int(time.time()),
    'exp': int(time.time()) + (5 * 365 * 24 * 60 * 60)  # 5 Jahre
}
print(jwt.encode(payload, '''$jwt_secret''', algorithm='HS256'))
PYTHON
}

# Hauptlogik
main() {
    check_requirements
    echo ""
    echo -e "${YELLOW}Generiere Secrets...${NC}"
    echo ""

    # JWT Secret (min 32 Zeichen, empfohlen 64)
    echo -n "  JWT Secret................ "
    JWT_SECRET=$(generate_base64 48)
    echo -e "${GREEN}✓${NC}"

    # Postgres Passwort (nur alphanumerisch für URL-Kompatibilität)
    echo -n "  PostgreSQL Passwort....... "
    POSTGRES_PASSWORD=$(generate_alphanum 32)
    echo -e "${GREEN}✓${NC}"

    # Dashboard Passwort
    echo -n "  Dashboard Passwort........ "
    DASHBOARD_PASSWORD=$(generate_alphanum 16)
    echo -e "${GREEN}✓${NC}"

    # Weitere Secrets
    echo -n "  Secret Key Base........... "
    SECRET_KEY_BASE=$(generate_base64 48)
    echo -e "${GREEN}✓${NC}"

    echo -n "  Vault Encryption Key...... "
    VAULT_ENC_KEY=$(generate_hex 16)
    echo -e "${GREEN}✓${NC}"

    echo -n "  Logflare API Key.......... "
    LOGFLARE_API_KEY=$(generate_alphanum 32)
    echo -e "${GREEN}✓${NC}"

    echo -n "  Logflare Private Key...... "
    LOGFLARE_PRIVATE_KEY=$(generate_alphanum 32)
    echo -e "${GREEN}✓${NC}"

    # JWT Keys generieren
    echo -n "  Anon Key (JWT)............ "
    ANON_KEY=$(generate_jwt "anon" "$JWT_SECRET")
    echo -e "${GREEN}✓${NC}"

    echo -n "  Service Role Key (JWT).... "
    SERVICE_ROLE_KEY=$(generate_jwt "service_role" "$JWT_SECRET")
    echo -e "${GREEN}✓${NC}"

    echo ""

    # Backup von existierender Datei
    if [ -f "$OUTPUT_FILE" ]; then
        BACKUP_FILE="${OUTPUT_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$OUTPUT_FILE" "$BACKUP_FILE"
        echo -e "${YELLOW}Existierende Datei gesichert nach: $(basename "$BACKUP_FILE")${NC}"
    fi

    # Schreibe in tfvars Datei
    cat > "$OUTPUT_FILE" << EOF
# =============================================================================
# Auto-generierte Secrets
# =============================================================================
# Generiert am: $(date -Iseconds)
# Generator: scripts/generate-secrets.sh
#
# WICHTIG: Diese Datei NIEMALS in Git committen!
# =============================================================================

# PostgreSQL
postgres_password = "$POSTGRES_PASSWORD"

# JWT
jwt_secret       = "$JWT_SECRET"
anon_key         = "$ANON_KEY"
service_role_key = "$SERVICE_ROLE_KEY"

# Dashboard
dashboard_password = "$DASHBOARD_PASSWORD"

# Weitere Secrets
secret_key_base  = "$SECRET_KEY_BASE"
vault_enc_key    = "$VAULT_ENC_KEY"
logflare_api_key     = "$LOGFLARE_API_KEY"
logflare_private_key = "$LOGFLARE_PRIVATE_KEY"
EOF

    echo -e "${GREEN}✓ Secrets geschrieben nach: $OUTPUT_FILE${NC}"
    echo ""

    # Warnung wenn Datei nicht in .gitignore
    if [ -f "$PROJECT_DIR/.gitignore" ]; then
        if ! grep -q "secrets.auto.tfvars" "$PROJECT_DIR/.gitignore" 2>/dev/null; then
            echo -e "${YELLOW}⚠ WARNUNG: secrets.auto.tfvars ist nicht in .gitignore!${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ WARNUNG: Keine .gitignore gefunden!${NC}"
    fi

    echo ""
    echo -e "${BLUE}==============================================================================${NC}"
    echo -e "${GREEN}Secrets wurden erfolgreich generiert!${NC}"
    echo ""
    echo "Nächste Schritte:"
    echo "  1. terraform.tfvars erstellen (siehe terraform/terraform.tfvars.example)"
    echo "  2. ./scripts/deploy.sh --env dev --init --apply"
    echo -e "${BLUE}==============================================================================${NC}"
}

main "$@"
