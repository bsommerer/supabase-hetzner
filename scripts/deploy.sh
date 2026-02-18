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
#   --env ENV           Wählt die Umgebung (dev, prod, etc.)
#   --init              Initialisiert Terraform und generiert Secrets
#   --plan              Zeigt Terraform Plan an
#   --apply             Führt terraform apply aus
#   --destroy           Zerstört die Infrastruktur
#   --restore [DATE]    Stellt Backup wieder her (ohne Datum: interaktive Auswahl)
#   --list-backups      Zeigt verfügbare Backups an
#   --backup-now        Führt sofortiges Backup aus
#   --status            Zeigt Status der Infrastruktur
#   --ssh               Verbindet via SSH zum Server
#   --logs [SERVICE]    Zeigt Docker Logs (optional: spezifischer Service)
#   --help              Zeigt diese Hilfe
#
# Beispiele:
#   ./deploy.sh --env dev --init --apply    # Dev erstmalig deployen
#   ./deploy.sh --env prod --apply          # Prod deployen
#   ./deploy.sh --env dev --status          # Dev-Status anzeigen
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_DIR/terraform"
ENVIRONMENTS_DIR="$PROJECT_DIR/environments"

# Aktive Umgebung
ACTIVE_ENV=""
ENV_DIR=""

# SSH Optionen - kein Passwort, nur Key Auth
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=no"

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

# =============================================================================
# Multi-Environment
# =============================================================================

resolve_environment() {
    if [ -z "$ACTIVE_ENV" ]; then
        # Kein --env angegeben: Auto-Detection
        if [ -d "$ENVIRONMENTS_DIR/prod" ]; then
            ACTIVE_ENV="prod"
        elif [ -d "$ENVIRONMENTS_DIR/dev" ]; then
            ACTIVE_ENV="dev"
        else
            # Legacy-Modus: keine environments/, verwende terraform/ direkt
            ENV_DIR=""
            return
        fi
    fi

    ENV_DIR="$ENVIRONMENTS_DIR/$ACTIVE_ENV"
    if [ ! -d "$ENV_DIR" ]; then
        print_error "Umgebung '$ACTIVE_ENV' nicht gefunden: $ENV_DIR"
        print_info "Erstelle mit: mkdir -p $ENV_DIR"
        exit 1
    fi

    print_info "Umgebung: $ACTIVE_ENV"
}

get_tfvars_path() {
    if [ -n "$ENV_DIR" ]; then
        echo "$ENV_DIR/terraform.tfvars"
    else
        echo "$TERRAFORM_DIR/terraform.tfvars"
    fi
}

get_secrets_path() {
    if [ -n "$ENV_DIR" ]; then
        echo "$ENV_DIR/secrets.auto.tfvars"
    else
        echo "$TERRAFORM_DIR/secrets.auto.tfvars"
    fi
}

get_tf_var_args() {
    if [ -n "$ENV_DIR" ]; then
        echo "-var-file=$ENV_DIR/terraform.tfvars -var-file=$ENV_DIR/secrets.auto.tfvars"
    fi
}

select_workspace() {
    if [ -n "$ACTIVE_ENV" ]; then
        cd "$TERRAFORM_DIR"
        terraform workspace select "$ACTIVE_ENV" 2>/dev/null || \
            terraform workspace new "$ACTIVE_ENV"
    fi
}

# =============================================================================
# Deployment Status Detection
# =============================================================================

check_deployment_status() {
    local server_ip="$1"

    # Status Codes:
    # 0 = Komplett deployed, nur Tests nötig
    # 1 = Server läuft, Cloud-Init läuft noch
    # 2 = Server existiert, aber nicht erreichbar (Problem)
    # 3 = Kein Server deployed

    # Prüfe ob Server in Terraform State existiert
    if ! terraform -chdir="$TERRAFORM_DIR" state list 2>/dev/null | grep -q "hcloud_server.supabase"; then
        echo "3" # Nichts deployed
        return
    fi

    # Server existiert im State, hole IP
    if [ -z "$server_ip" ]; then
        echo "2" # Server existiert aber keine IP
        return
    fi

    # Prüfe SSH Erreichbarkeit (kurzer Timeout)
    # UserKnownHostsFile=/dev/null weil Server bei Redeployment neuen Host Key bekommt
    if ! ssh $SSH_OPTS -o ConnectTimeout=3 -o BatchMode=yes -o LogLevel=ERROR \
            "ubuntu@$server_ip" "exit 0" 2>/dev/null; then
        echo "2" # Server nicht erreichbar
        return
    fi

    # SSH erreichbar, prüfe Cloud-Init Status
    local cloud_init_status=$(ssh $SSH_OPTS -o BatchMode=yes "ubuntu@$server_ip" \
        "[ -f /var/lib/cloud/instance/boot-finished ] && echo 'done' || echo 'running'" 2>/dev/null)

    if [ "$cloud_init_status" = "running" ]; then
        echo "1" # Cloud-Init läuft noch
        return
    fi

    # Alles fertig
    echo "0"
}

# =============================================================================
# Deployment-Überwachung
# =============================================================================

wait_for_ssh() {
    local server_ip="$1"
    local max_attempts=60  # 5 Minuten
    local attempt=1

    print_info "Warte auf SSH-Verfügbarkeit ($server_ip)..."

    while [ $attempt -le $max_attempts ]; do
        if ssh $SSH_OPTS -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR \
               "ubuntu@$server_ip" "exit 0" 2>/dev/null; then
            print_success "SSH ist verfügbar"
            return 0
        fi

        echo -ne "\r  ${YELLOW}⏳${NC} Warte auf SSH... [$attempt/$max_attempts]"
        sleep 5
        ((attempt++))
    done

    echo ""
    print_error "SSH-Timeout nach $max_attempts Versuchen"
    return 1
}

run_deployment_tests() {
    local server_ip="$1"
    local domain="$2"

    print_header "Deployment Verifizierung"

    # Prüfe ob test-deployment.sh existiert
    if [ ! -f "$SCRIPT_DIR/test-deployment.sh" ]; then
        print_warning "test-deployment.sh nicht gefunden - überspringe Tests"
        return 0
    fi

    # Tests ausführen
    "$SCRIPT_DIR/test-deployment.sh" "$server_ip" "$domain"
    local test_result=$?

    if [ $test_result -eq 0 ]; then
        return 0
    else
        print_error "Tests fehlgeschlagen"
        return 1
    fi
}

run_remote_restore() {
    local server_ip="$1"
    local restore_date="$2"

    print_header "Restore auf laufendem Server"

    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  WARNUNG: Dies überschreibt die aktuelle Datenbank!        ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    print_info "Server: $server_ip"
    print_info "Backup-Datum: $restore_date"
    echo ""

    read -p "Restore durchführen? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        print_info "Restore abgebrochen"
        return 0
    fi

    echo ""
    print_info "Starte Restore via SSH..."
    echo ""

    ssh $SSH_OPTS "ubuntu@$server_ip" \
        "/opt/supabase/scripts/restore.sh $restore_date"
    local restore_result=$?

    echo ""
    if [ $restore_result -eq 0 ]; then
        print_success "Restore abgeschlossen"
    else
        print_error "Restore fehlgeschlagen (Exit Code: $restore_result)"
        return 1
    fi
}

# =============================================================================
# Verwendung
# =============================================================================

usage() {
    cat << EOF
${BLUE}Supabase Deployment Script${NC}

Verwendung: $0 [OPTIONEN]

Optionen:
  ${GREEN}--env ENV${NC}           Wählt die Umgebung (dev, prod, etc.)
  ${GREEN}--init${NC}              Initialisiert Terraform und generiert Secrets
  ${GREEN}--plan${NC}              Zeigt Terraform Plan an
  ${GREEN}--apply${NC}             Führt terraform apply aus
  ${GREEN}--destroy${NC}           Zerstört die Infrastruktur
  ${GREEN}--restore [DATE]${NC}     Stellt Backup wieder her (ohne Datum: interaktive Auswahl)
  ${GREEN}--list-backups${NC}      Zeigt verfügbare Backups an
  ${GREEN}--backup-now${NC}        Führt sofortiges Backup aus
  ${GREEN}--test-backup${NC}       Testet Backup/Restore Funktionalität lokal
  ${GREEN}--test${NC}              Testet das aktuelle Deployment (SSH, Docker, DNS, HTTPS, APIs, DB)
  ${GREEN}--status${NC}            Zeigt Status der Infrastruktur
  ${GREEN}--ssh${NC}               Verbindet via SSH zum Server
  ${GREEN}--logs [SERVICE]${NC}    Zeigt Docker Logs (optional: spezifischer Service)
  ${GREEN}--help${NC}              Zeigt diese Hilfe

Beispiele:
  ${CYAN}$0 --env dev --init --apply${NC}          # Dev erstmalig deployen
  ${CYAN}$0 --env prod --apply${NC}                # Prod deployen
  ${CYAN}$0 --env dev --status${NC}                # Dev-Status anzeigen
  ${CYAN}$0 --env prod --restore${NC}              # Prod-Backup interaktiv restore
  ${CYAN}$0 --env dev --logs kong${NC}             # Dev Kong Logs
  ${CYAN}$0 --init --apply${NC}                    # Erstmaliges Deployment
  ${CYAN}$0 --restore 2024-01-15${NC}              # Restore von spezifischem Datum
  ${CYAN}$0 --backup-now${NC}                      # Manuelles Backup

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
    local tfvars_file
    tfvars_file=$(get_tfvars_path)

    if [ ! -f "$tfvars_file" ]; then
        print_error "terraform.tfvars nicht gefunden: $tfvars_file"
        echo ""
        if [ -n "$ENV_DIR" ]; then
            echo "Erstelle terraform.tfvars für Umgebung '$ACTIVE_ENV':"
            echo "  cp environments/terraform.tfvars.example $ENV_DIR/terraform.tfvars"
        else
            echo "Erstelle terraform.tfvars:"
            echo "  cp environments/terraform.tfvars.example terraform/terraform.tfvars"
        fi
        exit 1
    fi
}

check_secrets() {
    local secrets_file
    secrets_file=$(get_secrets_path)

    if [ ! -f "$secrets_file" ]; then
        print_warning "secrets.auto.tfvars nicht gefunden: $secrets_file"
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
    local secrets_file
    secrets_file=$(get_secrets_path)
    "$SCRIPT_DIR/generate-secrets.sh" "$secrets_file"
}

terraform_init() {
    print_header "Initialisiere Terraform"
    cd "$TERRAFORM_DIR"

    local init_args=()
    if [ -f "$TERRAFORM_DIR/backend.tfvars" ]; then
        init_args+=("-backend-config=backend.tfvars")
    fi

    terraform init "${init_args[@]}"
    select_workspace
    print_success "Terraform initialisiert"
}

terraform_plan() {
    print_header "Terraform Plan"
    check_tfvars
    check_secrets
    cd "$TERRAFORM_DIR"
    select_workspace
    # shellcheck disable=SC2046
    terraform plan $(get_tf_var_args)
}

terraform_apply() {
    local restore_date="${1:-}"

    print_header "Smart Deployment"
    check_tfvars
    check_secrets
    cd "$TERRAFORM_DIR"
    select_workspace

    # Hole Server IP aus State (falls vorhanden)
    local server_ip=$(terraform output -raw server_ip 2>/dev/null || echo "")
    local domain=$(terraform output -raw supabase_url 2>/dev/null | sed 's|https://||')

    # Prüfe Deployment-Status
    local status=$(check_deployment_status "$server_ip")

    case $status in
        0|1)
            # === Server läuft bereits ===
            print_success "Server bereits deployed und erreichbar!"
            echo ""
            print_info "Server IP: $server_ip"
            print_info "Domain: $domain"
            echo ""

            # Restore auf laufendem Server via SSH
            if [ -n "$restore_date" ]; then
                run_remote_restore "$server_ip" "$restore_date"
            fi

            print_info "Starte Deployment-Tests..."
            echo ""

            if run_deployment_tests "$server_ip" "$domain"; then
                echo ""
                echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${GREEN}║  ✓  DEPLOYMENT VERIFIZIERT                                 ║${NC}"
                echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
            else
                echo ""
                print_warning "Tests fehlgeschlagen - bitte manuell prüfen"
                echo ""
                print_info "Debug-Befehle:"
                echo "  $0 --ssh              # SSH zum Server"
                echo "  $0 --logs             # Logs anzeigen"
                echo "  $0 --status           # Status prüfen"
            fi
            echo ""
            show_outputs
            return 0
            ;;

        2)
            # === Server existiert aber Problem ===
            print_warning "Server existiert in Terraform State, ist aber nicht erreichbar"
            echo ""
            if [ -n "$server_ip" ]; then
                print_info "Server IP: $server_ip"
            fi
            echo ""
            print_info "Mögliche Ursachen:"
            echo "  • Server bootet noch (warte 1-2 Minuten)"
            echo "  • Firewall blockiert SSH"
            echo "  • Server wurde manuell gelöscht aber State nicht aktualisiert"
            echo ""
            read -p "Terraform apply erneut ausführen? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_info "Abgebrochen. Nutze '$0 --destroy' um State zu bereinigen."
                return 1
            fi
            ;;

        3)
            # === Nichts deployed ===
            print_info "Keine Infrastruktur gefunden, starte neues Deployment"
            echo ""
            ;;
    esac

    # Terraform apply ausführen (bei Status 2 oder 3)
    local var_args
    var_args=$(get_tf_var_args)
    local apply_args=("-auto-approve")
    for arg in $var_args; do
        apply_args+=("$arg")
    done
    if [ -n "$restore_date" ]; then
        print_info "Restore von Backup: $restore_date"
        apply_args+=("-var=restore_from_backup=true")
        apply_args+=("-var=backup_date=$restore_date")
    fi

    print_info "Führe terraform apply aus..."
    echo ""
    terraform apply "${apply_args[@]}"
    local apply_result=$?

    if [ $apply_result -ne 0 ]; then
        print_error "Terraform apply fehlgeschlagen"
        return 1
    fi

    echo ""
    print_success "Terraform apply abgeschlossen!"

    # Server IP und Domain aus Outputs holen
    server_ip=$(terraform output -raw server_ip 2>/dev/null || echo "")
    domain=$(terraform output -raw supabase_url 2>/dev/null | sed 's|https://||')

    if [ -z "$server_ip" ]; then
        print_error "Konnte Server IP nicht ermitteln"
        show_outputs
        return 1
    fi

    echo ""
    print_info "Server IP: $server_ip"
    print_info "Domain: $domain"
    echo ""

    # === PHASE 1: Warte auf SSH ===
    if ! wait_for_ssh "$server_ip"; then
        print_error "SSH nicht erreichbar - Deployment fehlgeschlagen"
        return 1
    fi

    echo ""

    # === PHASE 2: Automatische Tests ===
    if run_deployment_tests "$server_ip" "$domain"; then
        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  🎉  DEPLOYMENT ERFOLGREICH                                ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    else
        echo ""
        print_warning "Tests fehlgeschlagen - bitte manuell prüfen"
        echo ""
        print_info "Debug-Befehle:"
        echo "  $0 --ssh              # SSH zum Server"
        echo "  $0 --logs             # Logs anzeigen"
        echo "  $0 --status           # Status prüfen"
    fi

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
        select_workspace
        # shellcheck disable=SC2046
        terraform destroy $(get_tf_var_args)
        print_success "Infrastruktur zerstört"
    else
        print_info "Abgebrochen"
    fi
}

show_outputs() {
    cd "$TERRAFORM_DIR"
    select_workspace

    if terraform state list &> /dev/null; then
        echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│  Deployment Informationen                                   │${NC}"
        echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
        echo ""

        local server_ip=$(terraform output -raw server_ip 2>/dev/null || echo "N/A")
        local supabase_url=$(terraform output -raw supabase_url 2>/dev/null || echo "N/A")
        local portainer_url=$(terraform output -raw portainer_url 2>/dev/null || echo "N/A")

        echo "  Server IP:     $server_ip"
        echo "  Supabase:      $supabase_url"
        echo "  Portainer:     $portainer_url"
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
    select_workspace

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
        ssh $SSH_OPTS -o ConnectTimeout=5 -o BatchMode=yes "ubuntu@$server_ip" \
            "docker ps --format 'table {{.Names}}\t{{.Status}}'" 2>/dev/null || \
            print_warning "Konnte nicht zum Server verbinden"
    fi
}

connect_ssh() {
    cd "$TERRAFORM_DIR"
    select_workspace

    local server_ip=$(terraform output -raw server_ip 2>/dev/null || echo "")

    if [ -z "$server_ip" ]; then
        print_error "Keine Server IP gefunden"
        exit 1
    fi

    print_info "Verbinde zu ubuntu@$server_ip..."
    ssh $SSH_OPTS "ubuntu@$server_ip"
}

show_logs() {
    local service="${1:-}"

    cd "$TERRAFORM_DIR"
    select_workspace
    local server_ip=$(terraform output -raw server_ip 2>/dev/null || echo "")

    if [ -z "$server_ip" ]; then
        print_error "Keine Server IP gefunden"
        exit 1
    fi

    if [ -n "$service" ]; then
        print_info "Zeige Logs für Service: $service"
        ssh $SSH_OPTS "ubuntu@$server_ip" "cd /opt/supabase && docker compose logs -f --tail=100 $service"
    else
        print_info "Zeige alle Logs"
        ssh $SSH_OPTS "ubuntu@$server_ip" "cd /opt/supabase && docker compose logs -f --tail=50"
    fi
}

backup_now() {
    print_header "Manuelles Backup"

    cd "$TERRAFORM_DIR"
    select_workspace
    local server_ip=$(terraform output -raw server_ip 2>/dev/null || echo "")

    if [ -z "$server_ip" ]; then
        print_error "Keine Server IP gefunden"
        exit 1
    fi

    print_info "Starte Backup auf $server_ip..."
    ssh $SSH_OPTS "ubuntu@$server_ip" "docker exec backup /usr/bin/backup"
    print_success "Backup gestartet"

    echo ""
    print_info "Prüfe Backup-Status mit: $0 --logs backup"
}

load_s3_credentials() {
    check_tfvars
    local tfvars
    tfvars=$(get_tfvars_path)
    S3_ENDPOINT=$(grep 's3_endpoint' "$tfvars" | sed 's/.*=.*"\(.*\)"/\1/' | tr -d ' ')
    S3_ACCESS_KEY=$(grep 's3_access_key' "$tfvars" | sed 's/.*=.*"\(.*\)"/\1/' | tr -d ' ')
    S3_SECRET_KEY=$(grep 's3_secret_key' "$tfvars" | sed 's/.*=.*"\(.*\)"/\1/' | tr -d ' ')
    S3_BACKUP_BUCKET=$(grep 's3_backup_bucket' "$tfvars" | sed 's/.*=.*"\(.*\)"/\1/' | tr -d ' ')

    if [ -z "$S3_ENDPOINT" ] || [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_BACKUP_BUCKET" ]; then
        print_error "S3 Credentials nicht vollständig in terraform.tfvars"
        exit 1
    fi
}

fetch_backup_list() {
    docker run --rm \
        -e AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
        -e AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
        amazon/aws-cli \
        --endpoint-url "$S3_ENDPOINT" \
        s3 ls "s3://$S3_BACKUP_BUCKET/supabase/" \
        --human-readable 2>/dev/null | grep -E "backup-" | tail -20
}

list_backups() {
    print_header "Verfügbare Backups"
    load_s3_credentials
    print_info "Bucket: s3://$S3_BACKUP_BUCKET/supabase/"
    echo ""
    fetch_backup_list || print_warning "Keine Backups gefunden oder S3 nicht erreichbar"
}

select_backup() {
    print_header "Backup auswählen"
    load_s3_credentials
    print_info "Lade Backups von s3://$S3_BACKUP_BUCKET/supabase/ ..."
    echo ""

    local backup_lines
    backup_lines=$(fetch_backup_list)

    if [ -z "$backup_lines" ]; then
        print_error "Keine Backups gefunden"
        exit 1
    fi

    # Backup-Dateinamen extrahieren und nummeriert anzeigen (neueste zuerst)
    local -a backup_files
    while IFS= read -r line; do
        local filename=$(echo "$line" | awk '{print $NF}')
        backup_files+=("$filename")
    done <<< "$backup_lines"

    # Umkehren: neueste zuerst
    local -a reversed
    for (( i=${#backup_files[@]}-1; i>=0; i-- )); do
        reversed+=("${backup_files[$i]}")
    done

    for i in "${!reversed[@]}"; do
        local num=$((i + 1))
        # Datum aus Dateiname extrahieren (backup-YYYY-MM-DDTHH-MM-SS.tar.gz*)
        local display="${reversed[$i]}"
        echo -e "  ${GREEN}[$num]${NC} $display"
    done

    echo ""
    read -p "Backup Nummer wählen (1-${#reversed[@]}): " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#reversed[@]}" ]; then
        print_error "Ungültige Auswahl: $choice"
        exit 1
    fi

    local selected="${reversed[$((choice - 1))]}"
    # Datum aus Dateiname extrahieren (backup-YYYY-MM-DD...)
    RESTORE_DATE=$(echo "$selected" | grep -oP '\d{4}-\d{2}-\d{2}')
    print_success "Gewählt: $selected (Datum: $RESTORE_DATE)"
}

# =============================================================================
# Argument Parsing
# =============================================================================

INIT=false
PLAN=false
APPLY=false
DESTROY=false
RESTORE_DATE=""
LIST_BACKUPS=false
BACKUP_NOW=false
TEST_BACKUP=false
TEST=false
STATUS=false
SSH=false
LOGS=false
LOGS_SERVICE=""

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
            if [[ $# -gt 1 && ! "$2" =~ ^-- ]]; then
                RESTORE_DATE="$2"
                shift 2
            else
                RESTORE_DATE="__select__"
                shift
            fi
            ;;
        --list-backups)
            LIST_BACKUPS=true
            shift
            ;;
        --backup-now)
            BACKUP_NOW=true
            shift
            ;;
        --test-backup)
            TEST_BACKUP=true
            shift
            ;;
        --test)
            TEST=true
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
RESTORE=false
[ -n "$RESTORE_DATE" ] && RESTORE=true

if ! $INIT && ! $PLAN && ! $APPLY && ! $DESTROY && ! $RESTORE && ! $LIST_BACKUPS && ! $BACKUP_NOW && ! $TEST_BACKUP && ! $TEST && ! $STATUS && ! $SSH && ! $LOGS; then
    usage
fi

check_requirements
resolve_environment

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
    if [ "$RESTORE_DATE" = "__select__" ]; then
        select_backup
    fi
    terraform_apply "$RESTORE_DATE"
fi

# Restore ohne --apply: direkt auf laufendem Server
if $RESTORE && ! $APPLY; then
    if [ "$RESTORE_DATE" = "__select__" ]; then
        select_backup
    fi

    cd "$TERRAFORM_DIR"
    select_workspace
    restore_server_ip=$(terraform output -raw server_ip 2>/dev/null || echo "")

    if [ -z "$restore_server_ip" ]; then
        print_error "Keine Server IP gefunden - ist Infrastruktur deployed?"
        exit 1
    fi

    run_remote_restore "$restore_server_ip" "$RESTORE_DATE"
fi

if $TEST; then
    cd "$TERRAFORM_DIR"
    select_workspace
    local_server_ip=$(terraform output -raw server_ip 2>/dev/null || echo "")
    local_domain=$(terraform output -raw supabase_url 2>/dev/null | sed 's|https://||')

    if [ -z "$local_server_ip" ]; then
        print_error "Keine Server IP gefunden - ist Infrastruktur deployed?"
        exit 1
    fi

    run_deployment_tests "$local_server_ip" "$local_domain"
fi

if $LIST_BACKUPS; then
    list_backups
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
