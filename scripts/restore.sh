#!/bin/bash
# =============================================================================
# Supabase Restore Script (Disaster Recovery)
# =============================================================================
# Stellt ein Backup von Hetzner S3 wieder her.
#
# Dieses Skript wird sowohl lokal als auch via Cloud-init verwendet.
#
# Verwendung:
#   ./scripts/restore.sh YYYY-MM-DD
#   ./scripts/restore.sh --list
#
# =============================================================================
set -euo pipefail

# Farben für Output (falls Terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# =============================================================================
# Konfiguration
# =============================================================================

# Lade Umgebungsvariablen wenn vorhanden
if [ -f /opt/supabase/.env ]; then
    set -a
    source /opt/supabase/.env
    set +a
fi

# S3 Konfiguration (kann auch via Umgebungsvariablen gesetzt werden)
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_BACKUP_BUCKET="${S3_BACKUP_BUCKET:-supabase-backups}"
S3_BACKUP_PATH="${S3_BACKUP_PATH:-supabase}"

# Verzeichnisse
SUPABASE_DIR="${SUPABASE_DIR:-/opt/supabase}"
RESTORE_DIR="/tmp/supabase-restore"

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

usage() {
    cat << EOF
${BLUE}Supabase Restore Script${NC}

Verwendung: $0 [OPTION]

Optionen:
  ${GREEN}YYYY-MM-DD${NC}    Stellt Backup vom angegebenen Datum wieder her
  ${GREEN}--list${NC}        Zeigt verfügbare Backups an
  ${GREEN}--latest${NC}      Stellt das neueste Backup wieder her
  ${GREEN}--help${NC}        Zeigt diese Hilfe

Beispiele:
  ${YELLOW}$0 2024-01-15${NC}      # Restore von spezifischem Datum
  ${YELLOW}$0 --latest${NC}        # Neuestes Backup
  ${YELLOW}$0 --list${NC}          # Verfügbare Backups anzeigen

Umgebungsvariablen:
  S3_ENDPOINT         S3 Endpoint URL
  S3_BACKUP_BUCKET    Bucket Name (default: supabase-backups)
  AWS_ACCESS_KEY_ID   S3 Access Key
  AWS_SECRET_ACCESS_KEY  S3 Secret Key

EOF
    exit 0
}

check_requirements() {
    if [ -z "$S3_ENDPOINT" ]; then
        print_error "S3_ENDPOINT nicht gesetzt"
        exit 1
    fi

    if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
        print_error "AWS_ACCESS_KEY_ID nicht gesetzt"
        exit 1
    fi

    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI nicht installiert"
        echo "Installation: apt install awscli"
        exit 1
    fi
}

# =============================================================================
# S3 Funktionen
# =============================================================================

list_backups() {
    print_header "Verfügbare Backups"
    echo "Bucket: s3://$S3_BACKUP_BUCKET/$S3_BACKUP_PATH/"
    echo ""

    aws --endpoint-url "$S3_ENDPOINT" s3 ls "s3://$S3_BACKUP_BUCKET/$S3_BACKUP_PATH/" \
        --human-readable 2>/dev/null | grep -E "backup-[0-9]{4}" | tail -20 || \
        print_warning "Keine Backups gefunden oder Zugriffsfehler"
}

find_backup_file() {
    local date_pattern=$1

    aws --endpoint-url "$S3_ENDPOINT" s3 ls "s3://$S3_BACKUP_BUCKET/$S3_BACKUP_PATH/" 2>/dev/null | \
        grep "backup-$date_pattern" | tail -1 | awk '{print $4}'
}

get_latest_backup() {
    aws --endpoint-url "$S3_ENDPOINT" s3 ls "s3://$S3_BACKUP_BUCKET/$S3_BACKUP_PATH/" 2>/dev/null | \
        grep -E "backup-[0-9]{4}" | tail -1 | awk '{print $4}'
}

download_backup() {
    local backup_file=$1
    local target_file=$2

    echo "Lade Backup herunter: $backup_file"
    aws --endpoint-url "$S3_ENDPOINT" s3 cp \
        "s3://$S3_BACKUP_BUCKET/$S3_BACKUP_PATH/$backup_file" \
        "$target_file"
}

# =============================================================================
# Restore Funktionen
# =============================================================================

stop_services() {
    echo "Stoppe Docker Services..."
    cd "$SUPABASE_DIR"

    # Stoppe alle Services außer DB
    docker compose stop studio kong auth rest realtime storage meta functions analytics vector imgproxy edge-runtime pooler 2>/dev/null || true

    print_success "Services gestoppt"
}

start_database() {
    echo "Starte Datenbank..."
    cd "$SUPABASE_DIR"
    docker compose up -d db

    # Warte auf Datenbank
    echo "Warte auf Datenbank-Initialisierung..."
    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if docker compose exec -T db pg_isready -U postgres &>/dev/null; then
            print_success "Datenbank bereit"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    print_error "Datenbank nicht bereit nach $max_attempts Versuchen"
    return 1
}

restore_database() {
    local dump_file=$1

    if [ ! -f "$dump_file" ]; then
        print_warning "Kein SQL Dump gefunden: $dump_file"
        return 1
    fi

    echo "Stelle Datenbank wieder her..."
    cd "$SUPABASE_DIR"

    # Restore via pg_restore oder psql je nach Format
    if file "$dump_file" | grep -q "PostgreSQL"; then
        # Custom format dump
        docker compose exec -T db pg_restore -U postgres -d postgres --clean --if-exists < "$dump_file" 2>/dev/null || true
    else
        # SQL dump
        docker compose exec -T db psql -U postgres < "$dump_file"
    fi

    print_success "Datenbank wiederhergestellt"
}

restore_volumes() {
    local restore_dir=$1

    echo "Stelle Volumes wieder her..."

    # Liste der Volume-Verzeichnisse aus dem Backup
    for volume_dir in "$restore_dir"/backup/*/; do
        if [ -d "$volume_dir" ]; then
            local volume_name=$(basename "$volume_dir")
            echo "  Restore: $volume_name"

            # Je nach Volume-Typ unterschiedlich behandeln
            case $volume_name in
                db-data)
                    # Datenbank-Daten werden über SQL Dump wiederhergestellt
                    print_warning "  db-data wird via SQL Dump wiederhergestellt"
                    ;;
                *)
                    # Andere Volumes direkt kopieren
                    docker volume create "supabase_$volume_name" 2>/dev/null || true
                    # Volume mounten und Daten kopieren
                    docker run --rm \
                        -v "supabase_$volume_name:/target" \
                        -v "$volume_dir:/source:ro" \
                        alpine sh -c "rm -rf /target/* && cp -a /source/. /target/" 2>/dev/null || \
                        print_warning "  Konnte $volume_name nicht wiederherstellen"
                    ;;
            esac
        fi
    done

    print_success "Volumes wiederhergestellt"
}

start_all_services() {
    echo "Starte alle Services..."
    cd "$SUPABASE_DIR"
    docker compose up -d

    # Warte kurz
    sleep 10

    print_success "Alle Services gestartet"
}

cleanup() {
    echo "Räume temporäre Dateien auf..."
    rm -rf "$RESTORE_DIR"
    print_success "Aufgeräumt"
}

# =============================================================================
# Hauptfunktion
# =============================================================================

do_restore() {
    local backup_file=$1

    print_header "Supabase Disaster Recovery"
    echo "Backup: $backup_file"
    echo ""

    # Bestätigung anfordern (außer wenn non-interaktiv)
    if [ -t 0 ]; then
        echo -e "${YELLOW}WARNUNG: Dies überschreibt die aktuelle Datenbank!${NC}"
        read -p "Fortfahren? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            echo "Abgebrochen."
            exit 0
        fi
    fi

    # Arbeitsverzeichnis erstellen
    mkdir -p "$RESTORE_DIR"

    # 1. Backup herunterladen
    print_header "1/5 - Backup herunterladen"
    download_backup "$backup_file" "$RESTORE_DIR/backup.tar.gz"

    # 2. Backup entpacken
    print_header "2/5 - Backup entpacken"
    echo "Entpacke Backup..."
    tar -xzf "$RESTORE_DIR/backup.tar.gz" -C "$RESTORE_DIR"
    print_success "Backup entpackt"

    # Zeige Backup-Inhalt
    echo ""
    echo "Backup-Inhalt:"
    ls -la "$RESTORE_DIR/backup/" 2>/dev/null || ls -la "$RESTORE_DIR/" | head -10

    # 3. Services stoppen
    print_header "3/5 - Services stoppen"
    stop_services

    # 4. Datenbank wiederherstellen
    print_header "4/5 - Datenbank wiederherstellen"
    start_database

    # Suche SQL Dump
    local sql_dump=""
    for possible_dump in \
        "$RESTORE_DIR/backup/db-data/backup_dump.sql" \
        "$RESTORE_DIR/backup/config/backup_dump.sql" \
        "$RESTORE_DIR/backup_dump.sql"; do
        if [ -f "$possible_dump" ]; then
            sql_dump="$possible_dump"
            break
        fi
    done

    if [ -n "$sql_dump" ]; then
        restore_database "$sql_dump"
    else
        print_warning "Kein SQL Dump gefunden - nur Volume-Daten werden wiederhergestellt"
        restore_volumes "$RESTORE_DIR"
    fi

    # 5. Alle Services starten
    print_header "5/5 - Services starten"
    start_all_services

    # Aufräumen
    cleanup

    # Abschlussbericht
    print_header "Restore abgeschlossen"
    echo ""
    echo "Nächste Schritte:"
    echo "  1. Prüfe Services:  docker compose ps"
    echo "  2. Prüfe Logs:      docker compose logs -f"
    echo "  3. Teste Zugang:    https://$DOMAIN"
    echo ""
    print_success "Disaster Recovery erfolgreich!"
}

# =============================================================================
# Hauptprogramm
# =============================================================================

# Argument prüfen
if [ $# -eq 0 ]; then
    usage
fi

case "${1:-}" in
    --help|-h)
        usage
        ;;
    --list)
        check_requirements
        list_backups
        ;;
    --latest)
        check_requirements
        print_header "Suche neuestes Backup"
        BACKUP_FILE=$(get_latest_backup)
        if [ -z "$BACKUP_FILE" ]; then
            print_error "Kein Backup gefunden"
            exit 1
        fi
        echo "Neuestes Backup: $BACKUP_FILE"
        do_restore "$BACKUP_FILE"
        ;;
    20[0-9][0-9]-[0-9][0-9]-[0-9][0-9])
        # Datum im Format YYYY-MM-DD
        check_requirements
        BACKUP_DATE="$1"
        print_header "Suche Backup für $BACKUP_DATE"

        BACKUP_FILE=$(find_backup_file "$BACKUP_DATE")
        if [ -z "$BACKUP_FILE" ]; then
            print_error "Kein Backup für $BACKUP_DATE gefunden"
            echo ""
            list_backups
            exit 1
        fi

        echo "Gefunden: $BACKUP_FILE"
        do_restore "$BACKUP_FILE"
        ;;
    *)
        print_error "Ungültiges Argument: $1"
        echo ""
        usage
        ;;
esac
