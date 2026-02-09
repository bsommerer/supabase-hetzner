#!/bin/bash
# =============================================================================
# Deployment Test Script
# =============================================================================
# Testet alle wichtigen Services nach einem Deployment mit Live-Feedback
#
# Tests (in Reihenfolge):
#   1. SSH Konnektivität
#   2. Docker Services Status
#   3. DNS Auflösung (A Record + CNAMEs)
#   4. HTTP Erreichbarkeit (Port 80)
#   5. HTTPS & SSL Zertifikate (Port 443)
#   6. API Health Checks
#   7. PostgreSQL Database
#   8. Caddy Reverse Proxy
#
# Verwendung:
#   ./scripts/test-deployment.sh <SERVER_IP> <DOMAIN>
#
# Exit Codes:
#   0 - Alle Tests erfolgreich
#   1 - Tests fehlgeschlagen
# =============================================================================

set -euo pipefail

# SSH Optionen - kein Passwort, nur Key Auth
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=no -o BatchMode=yes"

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parameter
SERVER_IP="${1:-}"
DOMAIN="${2:-}"

if [ -z "$SERVER_IP" ] || [ -z "$DOMAIN" ]; then
    echo "Verwendung: $0 <SERVER_IP> <DOMAIN>"
    echo "Beispiel: $0 1.2.3.4 api.bsitservices.de"
    exit 1
fi

# Subdomains
PORTAINER_DOMAIN="portainer.$DOMAIN"

# =============================================================================
# Hilfsfunktionen
# =============================================================================

print_test_header() {
    echo ""
    echo -e "${CYAN}┌──────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  $1${NC}"
    echo -e "${CYAN}└──────────────────────────────────────────────────────────────┘${NC}"
}

print_waiting() {
    echo -ne "\r  ${YELLOW}⏳${NC} $1"
}

print_success() {
    echo -e "\r  ${GREEN}✓${NC} $1                                        "
}

print_failure() {
    echo -e "\r  ${RED}✗${NC} $1"
}

# Retry-Wrapper für Tests
retry_test() {
    local test_name="$1"
    local test_command="$2"
    local max_attempts="${3:-60}"
    local sleep_time="${4:-5}"
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        print_waiting "$test_name [$attempt/$max_attempts]..."

        if eval "$test_command" &>/dev/null; then
            print_success "$test_name"
            return 0
        fi

        sleep $sleep_time
        ((attempt++))
    done

    print_failure "$test_name (Timeout)"
    return 1
}

# =============================================================================
# Tests
# =============================================================================

test_ssh() {
    print_test_header "TEST 1: SSH Konnektivität"

    retry_test "SSH verfügbar" \
        "ssh $SSH_OPTS -o ConnectTimeout=5 ubuntu@$SERVER_IP 'exit 0'" \
        12 5
}

test_docker() {
    print_test_header "TEST 2: Docker Services"

    retry_test "Docker Daemon läuft" \
        "ssh $SSH_OPTS ubuntu@$SERVER_IP 'docker info'" \
        12 5

    echo ""

    # Wichtigste Container
    local services=("db" "kong" "auth" "rest" "storage" "caddy" "portainer" "backup")

    for service in "${services[@]}"; do
        retry_test "Container '$service' läuft" \
            "ssh $SSH_OPTS ubuntu@$SERVER_IP 'docker ps --format \"{{.Names}} {{.Status}}\" | grep -q \"$service.*Up\"'" \
            24 5 || return 1
    done

    echo ""
    print_success "Alle Docker Container laufen"
}

test_dns() {
    print_test_header "TEST 3: DNS Auflösung"

    # Öffentliche DNS Server nutzen statt lokale Resolver (kein Cache-Problem)
    local dns_servers=("1.1.1.1" "8.8.8.8" "9.9.9.9")
    local dns_names=("Cloudflare" "Google" "Quad9")

    # A Record prüfen über mehrere DNS Server
    for i in "${!dns_servers[@]}"; do
        retry_test "DNS: $DOMAIN → $SERVER_IP (${dns_names[$i]})" \
            "dig +short @${dns_servers[$i]} $DOMAIN | grep -q '$SERVER_IP'" \
            60 5
    done

    # CNAMEs prüfen über Cloudflare
    retry_test "DNS: $PORTAINER_DOMAIN (CNAME via Cloudflare)" \
        "dig +short @1.1.1.1 $PORTAINER_DOMAIN | grep -q '$DOMAIN\|$SERVER_IP'" \
        60 5

    echo ""
    print_success "Alle DNS Records OK"
}

test_http() {
    print_test_header "TEST 4: HTTP Erreichbarkeit (Let's Encrypt)"

    retry_test "HTTP: $DOMAIN (Port 80)" \
        "curl -sf -o /dev/null -w '%{http_code}' http://$DOMAIN | grep -qE '^[2-4][0-9]{2}$'" \
        24 5

    echo ""
    print_success "HTTP Erreichbarkeit OK"
}

test_https() {
    print_test_header "TEST 5: HTTPS & SSL Zertifikate"

    # Let's Encrypt kann 2-3 Minuten dauern
    retry_test "HTTPS: $DOMAIN (mit SSL)" \
        "curl -sf --max-time 10 -o /dev/null https://$DOMAIN" \
        36 5

    retry_test "HTTPS: $PORTAINER_DOMAIN (mit SSL)" \
        "curl -sf --max-time 10 -o /dev/null https://$PORTAINER_DOMAIN" \
        36 5

    echo ""
    print_success "Alle HTTPS Endpoints erreichbar"
}

test_apis() {
    print_test_header "TEST 6: API Health Checks"

    retry_test "Supabase API (Kong)" \
        "curl -sf -o /dev/null https://$DOMAIN/rest/v1/" \
        24 5

    retry_test "Portainer API" \
        "curl -sf -o /dev/null -w '%{http_code}' https://$PORTAINER_DOMAIN/ | grep -qE '^[2-3][0-9]{2}$'" \
        24 5

    echo ""
    print_success "Alle APIs antworten"
}

test_database() {
    print_test_header "TEST 7: PostgreSQL Database"

    retry_test "PostgreSQL antwortet" \
        "ssh $SSH_OPTS ubuntu@$SERVER_IP 'docker exec supabase-db pg_isready -U postgres'" \
        24 5

    retry_test "Supabase Schema initialisiert" \
        "ssh $SSH_OPTS ubuntu@$SERVER_IP 'docker exec supabase-db psql -U postgres -d postgres -c \"\dt auth.*\" | grep -q tables'" \
        36 5

    echo ""
    print_success "Database ist bereit"
}

test_caddy() {
    print_test_header "TEST 8: Caddy Reverse Proxy"

    retry_test "Caddy Container läuft" \
        "ssh $SSH_OPTS ubuntu@$SERVER_IP 'docker ps --format \"{{.Names}} {{.Status}}\" | grep -q \"caddy.*Up\"'" \
        24 5

    echo ""
    print_success "Caddy Reverse Proxy OK"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo "==================================================================="
    echo "  Deployment Tests"
    echo "==================================================================="
    echo ""
    echo "Server:  $SERVER_IP"
    echo "Domain:  $DOMAIN"
    echo ""
    echo "Dies kann 5-10 Minuten dauern..."
    echo "==================================================================="

    local failed=false

    test_ssh || failed=true
    [ "$failed" = false ] && test_docker || failed=true
    [ "$failed" = false ] && test_dns || failed=true
    [ "$failed" = false ] && test_http || failed=true
    [ "$failed" = false ] && test_https || failed=true
    [ "$failed" = false ] && test_apis || failed=true
    [ "$failed" = false ] && test_database || failed=true
    [ "$failed" = false ] && test_caddy || failed=true

    if [ "$failed" = true ]; then
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  ✗  TESTS FEHLGESCHLAGEN                                   ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        exit 1
    fi

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✓  ALLE TESTS ERFOLGREICH                                 ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Nächste Schritte:"
    echo "  • Supabase Studio:  https://$DOMAIN"
    echo "  • Portainer Setup:  https://$PORTAINER_DOMAIN"
    echo ""
    exit 0
}

trap 'echo ""; echo "Test abgebrochen"; exit 1' INT TERM

main
