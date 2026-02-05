#!/bin/bash
# =============================================================================
# Supabase Deployment Script
# =============================================================================
# Vollautomatisiertes Deployment von Supabase auf Hetzner Cloud.
#
# Verwendung:
#   ./scripts/deploy.sh [OPTIONEN]
#
# Optionen:
#   --init              Initialisiert Terraform und generiert Secrets
#   --plan              Zeigt Terraform Plan an
#   --apply             Führt terraform apply aus
#   --destroy           Zerstört die Infrastruktur
#   --restore DATE      Stellt Backup vom Datum wieder her (YYYY-MM-DD)
#   --backup-now        Führt sofortiges Backup aus
#   --test-backup       Testet Backup/Restore Funktionalität lokal
#   --status            Zeigt Status der Infrastruktur
#   --ssh               Verbindet via SSH zum Server
#   --logs [SERVICE]    Zeigt Docker Logs (optional: spezifischer Service)
#   --help              Zeigt diese Hilfe
#
# Beispiele:
#   ./deploy.sh --init --apply         # Erstmaliges Deployment
#   ./deploy.sh --apply --restore 2024-01-15  # Mit Restore
#   ./deploy.sh --status               # Zeigt Server Status
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_DIR/terraform"

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============================================================================
# Hilfsfunktionen
# =============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}==============================================================================${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}==============================================================================${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ $1${NC}"
}

usage() {
    cat << EOF
${BLUE}Supabase Deployment Script${NC}

Verwendung: $0 [OPTIONEN]

Optionen:
  ${GREEN}--init${NC}              Initialisiert Terraform und generiert Secrets
  ${GREEN}--plan${NC}              Zeigt Terraform Plan an
  ${GREEN}--apply${NC}             Führt terraform apply aus
  ${GREEN}--destroy${NC}           Zerstört die Infrastruktur
  ${GREEN}--restore DATE${NC}      Stellt Backup vom Datum wieder her (Format: YYYY-MM-DD)
  ${GREEN}--backup-now${NC}        Führt sofortiges Backup aus
  ${GREEN}--test-backup${NC}       Testet Backup/Restore Funktionalität lokal
  ${GREEN}--status${NC}            Zeigt Status der Infrastruktur
  ${GREEN}--ssh${NC}               Verbindet via SSH zum Server
  ${GREEN}--logs [SERVICE]${NC}    Zeigt Docker Logs (optional: spezifischer Service)
  ${GREEN}--help${NC}              Zeigt diese Hilfe

Beispiele:
  ${CYAN}$0 --init --apply${NC}                    # Erstmaliges Deployment
  ${CYAN}$0 --apply --restore 2024-01-15${NC}      # Deployment mit Restore
  ${CYAN}$0 --backup-now${NC}                      # Manuelles Backup
  ${CYAN}$0 --status${NC}                          # Server Status anzeigen
  ${CYAN}$0 --logs kong${NC}                       # Kong Logs anzeigen

EOF
    exit 0
}

# =============================================================================
# Prüfungen
# =============================================================================

check_requirements() {
    print_info "Prüfe Voraussetzungen..."
    local missing=()

    if ! command -v terraform &> /dev/null; then
        missing+=("terraform")
    fi

    if ! command -v openssl &> /dev/null; then
        missing+=("openssl")
    fi

    if ! command -v ssh &> /dev/null; then
        missing+=("ssh")
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        print_error "Folgende Programme fehlen: ${missing[*]}"
        echo ""
        echo "Installation:"
        echo "  terraform: https://www.terraform.io/downloads"
        echo "  openssl/ssh: Standard auf Linux/macOS"
        exit 1
    fi

    print_success "Alle Voraussetzungen erfüllt"
}

check_tfvars() {
    if [ ! -f "$TERRAFORM_DIR/terraform.tfvars" ]; then
        print_error "terraform.tfvars nicht gefunden!"
        echo ""
        echo "Erstelle terraform.tfvars basierend auf terraform.tfvars.example:"
        echo "  cp terraform/terraform.tfvars.example terraform/terraform.tfvars"
        echo "  # Dann Werte ausfüllen"
        exit 1
    fi
}

check_secrets() {
    if [ ! -f "$TERRAFORM_DIR/secrets.auto.tfvars" ]; then
        print_warning "secrets.auto.tfvars nicht gefunden"
        echo ""
        read -p "Secrets jetzt generieren? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            generate_secrets
        else
            exit 1
        fi
    fi
}

# =============================================================================
# Aktionen
# =============================================================================

generate_secrets() {
    print_header "Generiere Secrets"
    "$SCRIPT_DIR/generate-secrets.sh"
}

terraform_init() {
    print_header "Initialisiere Terraform"
    cd "$TERRAFORM_DIR"
    terraform init
    print_success "Terraform initialisiert"
}

terraform_plan() {
    print_header "Terraform Plan"
    check_tfvars
    check_secrets
    cd "$TERRAFORM_DIR"
    terraform plan
}

terraform_apply() {
    local restore_date="${1:-}"

    print_header "Terraform Apply"
    check_tfvars
    check_secrets
    cd "$TERRAFORM_DIR"

    local apply_args=()
    if [ -n "$restore_date" ]; then
        print_info "Restore von Backup: $restore_date"
        apply_args+=("-var=restore_from_backup=true")
        apply_args+=("-var=backup_date=$restore_date")
    fi

    terraform apply "${apply_args[@]}"

    echo ""
    print_success "Deployment abgeschlossen!"
    echo ""
    show_outputs
}

terraform_destroy() {
    print_header "Terraform Destroy"

    echo -e "${RED}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  WARNUNG: Dies zerstört die gesamte Infrastruktur!                         ║${NC}"
    echo -e "${RED}║                                                                             ║${NC}"
    echo -e "${RED}║  - VM wird gelöscht                                                        ║${NC}"
    echo -e "${RED}║  - Alle Docker Volumes (Datenbank, etc.) werden gelöscht                   ║${NC}"
    echo -e "${RED}║  - DNS Records werden entfernt                                             ║${NC}"
    echo -e "${RED}║                                                                             ║${NC}"
    echo -e "${RED}║  S3 Buckets (Backups, Storage) bleiben erhalten!                           ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    read -p "Zum Bestätigen 'yes' eingeben: " confirm
    if [ "$confirm" = "yes" ]; then
        cd "$TERRAFORM_DIR"
        terraform destroy
        print_success "Infrastruktur zerstört"
    else
        print_info "Abgebrochen"
    fi
}

show_outputs() {
    cd "$TERRAFORM_DIR"

    if terraform state list &> /dev/null; then
        echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│  Deployment Informationen                                   │${NC}"
        echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
        echo ""

        local server_ip=$(terraform output -raw server_ip 2>/dev/null || echo "N/A")
        local supabase_url=$(terraform output -raw supabase_url 2>/dev/null || echo "N/A")
        local portainer_url=$(terraform output -raw portainer_url 2>/dev/null || echo "N/A")
        local uptime_kuma_url=$(terraform output -raw uptime_kuma_url 2>/dev/null || echo "N/A")

        echo "  Server IP:     $server_ip"
        echo "  Supabase:      $supabase_url"
        echo "  Portainer:     $portainer_url"
        echo "  Uptime Kuma:   $uptime_kuma_url"
        echo ""
        echo "  SSH:           ssh ubuntu@$server_ip"
        echo ""
    else
        print_warning "Keine Terraform State gefunden"
    fi
}

show_status() {
    print_header "Infrastruktur Status"

    cd "$TERRAFORM_DIR"

    if ! terraform state list &> /dev/null; then
        print_warning "Keine Infrastruktur deployed"
        return
    fi

    show_outputs

    local server_ip=$(terraform output -raw server_ip 2>/dev/null || echo "")

    if [ -n "$server_ip" ]; then
        echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│  Docker Services                                            │${NC}"
        echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
        echo ""
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "ubuntu@$server_ip" \
            "cd /opt/supabase && docker compose ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'" 2>/dev/null || \
            print_warning "Konnte nicht zum Server verbinden"
    fi
}

connect_ssh() {
    cd "$TERRAFORM_DIR"

    local server_ip=$(terraform output -raw server_ip 2>/dev/null || echo "")

    if [ -z "$server_ip" ]; then
        print_error "Keine Server IP gefunden"
        exit 1
    fi

    print_info "Verbinde zu ubuntu@$server_ip..."
    ssh "ubuntu@$server_ip"
}

show_logs() {
    local service="${1:-}"

    cd "$TERRAFORM_DIR"
    local server_ip=$(terraform output -raw server_ip 2>/dev/null || echo "")

    if [ -z "$server_ip" ]; then
        print_error "Keine Server IP gefunden"
        exit 1
    fi

    if [ -n "$service" ]; then
        print_info "Zeige Logs für Service: $service"
        ssh "ubuntu@$server_ip" "cd /opt/supabase && docker compose logs -f --tail=100 $service"
    else
        print_info "Zeige alle Logs"
        ssh "ubuntu@$server_ip" "cd /opt/supabase && docker compose logs -f --tail=50"
    fi
}

backup_now() {
    print_header "Manuelles Backup"

    cd "$TERRAFORM_DIR"
    local server_ip=$(terraform output -raw server_ip 2>/dev/null || echo "")

    if [ -z "$server_ip" ]; then
        print_error "Keine Server IP gefunden"
        exit 1
    fi

    print_info "Starte Backup auf $server_ip..."
    ssh "ubuntu@$server_ip" "docker exec backup /bin/sh -c '/usr/local/bin/backup'"
    print_success "Backup gestartet"

    echo ""
    print_info "Prüfe Backup-Status mit: $0 --logs backup"
}

# =============================================================================
# Argument Parsing
# =============================================================================

INIT=false
PLAN=false
APPLY=false
DESTROY=false
RESTORE_DATE=""
BACKUP_NOW=false
TEST_BACKUP=false
STATUS=false
SSH=false
LOGS=false
LOGS_SERVICE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --init)
            INIT=true
            shift
            ;;
        --plan)
            PLAN=true
            shift
            ;;
        --apply)
            APPLY=true
            shift
            ;;
        --destroy)
            DESTROY=true
            shift
            ;;
        --restore)
            RESTORE_DATE="$2"
            shift 2
            ;;
        --backup-now)
            BACKUP_NOW=true
            shift
            ;;
        --test-backup)
            TEST_BACKUP=true
            shift
            ;;
        --status)
            STATUS=true
            shift
            ;;
        --ssh)
            SSH=true
            shift
            ;;
        --logs)
            LOGS=true
            if [[ $# -gt 1 && ! "$2" =~ ^-- ]]; then
                LOGS_SERVICE="$2"
                shift
            fi
            shift
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

# Mindestens eine Option erforderlich
if ! $INIT && ! $PLAN && ! $APPLY && ! $DESTROY && ! $BACKUP_NOW && ! $TEST_BACKUP && ! $STATUS && ! $SSH && ! $LOGS; then
    usage
fi

check_requirements

if $INIT; then
    generate_secrets
    terraform_init
fi

if $PLAN; then
    terraform_plan
fi

if $DESTROY; then
    terraform_destroy
    exit 0
fi

if $APPLY; then
    terraform_apply "$RESTORE_DATE"
fi

if $BACKUP_NOW; then
    backup_now
fi

if $TEST_BACKUP; then
    "$SCRIPT_DIR/test-backup.sh"
fi

if $STATUS; then
    show_status
fi

if $SSH; then
    connect_ssh
fi

if $LOGS; then
    show_logs "$LOGS_SERVICE"
fi
