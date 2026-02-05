#!/bin/bash
# =============================================================================
# Supabase Restore Script (Server-Version)
# =============================================================================
# Stellt ein Backup von Hetzner S3 wieder her.
#
# Verwendung:
#   /opt/supabase/scripts/restore.sh YYYY-MM-DD
#   /opt/supabase/scripts/restore.sh --list
#   /opt/supabase/scripts/restore.sh --latest
#
# =============================================================================
set -euo pipefail

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Konfiguration
# =============================================================================

SUPABASE_DIR="/opt/supabase"
RESTORE_DIR="/tmp/supabase-restore"

# Lade Umgebungsvariablen
if [ -f "$SUPABASE_DIR/.env" ]; then
    set -a
    source "$SUPABASE_DIR/.env"
    set +a
else
    echo -e "${RED}ERROR: $SUPABASE_DIR/.env nicht gefunden${NC}"
    exit 1
fi

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
  YYYY-MM-DD    Stellt Backup vom angegebenen Datum wieder her
  --list        Zeigt verfügbare Backups an
  --latest      Stellt das neueste Backup wieder her
  --help        Zeigt diese Hilfe

Beispiele:
  $0 2024-01-15      # Restore von spezifischem Datum
  $0 --latest        # Neuestes Backup
  $0 --list          # Verfügbare Backups anzeigen

EOF
    exit 0
}

# =============================================================================
# S3 Funktionen
# =============================================================================

list_backups() {
    print_header "Verfügbare Backups"
    echo "Bucket: s3://$S3_BACKUP_BUCKET/supabase/"
    echo ""

    aws --endpoint-url "$S3_ENDPOINT" s3 ls "s3://$S3_BACKUP_BUCKET/supabase/" \
        --human-readable 2>/dev/null | grep -E "backup-[0-9]{4}" | tail -20 || \
        print_warning "Keine Backups gefunden"
}

find_backup_file() {
    local date_pattern=$1
    aws --endpoint-url "$S3_ENDPOINT" s3 ls "s3://$S3_BACKUP_BUCKET/supabase/" 2>/dev/null | \
        grep "backup-$date_pattern" | tail -1 | awk '{print $4}'
}

get_latest_backup() {
    aws --endpoint-url "$S3_ENDPOINT" s3 ls "s3://$S3_BACKUP_BUCKET/supabase/" 2>/dev/null | \
        grep -E "backup-[0-9]{4}" | tail -1 | awk '{print $4}'
}

download_backup() {
    local backup_file=$1
    local target_file=$2

    echo "Lade Backup herunter: $backup_file"
    aws --endpoint-url "$S3_ENDPOINT" s3 cp \
        "s3://$S3_BACKUP_BUCKET/supabase/$backup_file" \
        "$target_file"
}

# =============================================================================
# Restore Funktionen
# =============================================================================

stop_services() {
    echo "Stoppe Docker Services..."
    cd "$SUPABASE_DIR"
    docker compose down || true
    print_success "Services gestoppt"
}

start_database() {
    echo "Starte Datenbank..."
    cd "$SUPABASE_DIR"
    docker compose up -d db

    echo "Warte auf Datenbank..."
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

    print_error "Datenbank nicht bereit"
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
    docker compose exec -T db psql -U postgres < "$dump_file"
    print_success "Datenbank wiederhergestellt"
}

start_all_services() {
    echo "Starte alle Services..."
    cd "$SUPABASE_DIR"
    docker compose up -d
    sleep 10
    print_success "Alle Services gestartet"
}

cleanup() {
    echo "Räume auf..."
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

    # Bestätigung (wenn interaktiv)
    if [ -t 0 ]; then
        echo -e "${YELLOW}WARNUNG: Dies überschreibt die aktuelle Datenbank!${NC}"
        read -p "Fortfahren? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            echo "Abgebrochen."
            exit 0
        fi
    fi

    mkdir -p "$RESTORE_DIR"

    # 1. Download
    print_header "1/5 - Backup herunterladen"
    download_backup "$backup_file" "$RESTORE_DIR/backup.tar.gz"

    # 2. Entpacken
    print_header "2/5 - Backup entpacken"
    tar -xzf "$RESTORE_DIR/backup.tar.gz" -C "$RESTORE_DIR"
    print_success "Backup entpackt"

    # 3. Stop
    print_header "3/5 - Services stoppen"
    stop_services

    # 4. Restore
    print_header "4/5 - Datenbank wiederherstellen"
    start_database

    local sql_dump=""
    for f in "$RESTORE_DIR"/backup/db-data/backup_dump.sql "$RESTORE_DIR"/backup_dump.sql; do
        if [ -f "$f" ]; then
            sql_dump="$f"
            break
        fi
    done

    if [ -n "$sql_dump" ]; then
        restore_database "$sql_dump"
    else
        print_warning "Kein SQL Dump gefunden"
    fi

    # 5. Start
    print_header "5/5 - Services starten"
    start_all_services

    cleanup

    print_header "Restore abgeschlossen"
    echo "Prüfe: docker compose ps"
    print_success "Disaster Recovery erfolgreich!"
}

# =============================================================================
# Main
# =============================================================================

if [ $# -eq 0 ]; then
    usage
fi

case "${1:-}" in
    --help|-h)
        usage
        ;;
    --list)
        list_backups
        ;;
    --latest)
        print_header "Suche neuestes Backup"
        BACKUP_FILE=$(get_latest_backup)
        if [ -z "$BACKUP_FILE" ]; then
            print_error "Kein Backup gefunden"
            exit 1
        fi
        echo "Gefunden: $BACKUP_FILE"
        do_restore "$BACKUP_FILE"
        ;;
    20[0-9][0-9]-[0-9][0-9]-[0-9][0-9])
        BACKUP_DATE="$1"
        print_header "Suche Backup für $BACKUP_DATE"
        BACKUP_FILE=$(find_backup_file "$BACKUP_DATE")
        if [ -z "$BACKUP_FILE" ]; then
            print_error "Kein Backup für $BACKUP_DATE gefunden"
            list_backups
            exit 1
        fi
        echo "Gefunden: $BACKUP_FILE"
        do_restore "$BACKUP_FILE"
        ;;
    *)
        print_error "Ungültiges Argument: $1"
        usage
        ;;
esac
