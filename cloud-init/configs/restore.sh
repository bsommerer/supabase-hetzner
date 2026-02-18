#!/bin/bash
# =============================================================================
# Supabase Restore Script (Server-Version)
# =============================================================================
# Stellt ein Backup von S3 wieder her.
# Folgt den Supabase Best Practices:
#   - 3 separate Dumps: roles, schema, data
#   - Restore mit --single-transaction und session_replication_role = replica
#   - Dump wird in den Container kopiert (docker cp + psql -f)
#
# Verwendung:
#   /opt/supabase/scripts/restore.sh YYYY-MM-DD
#   /opt/supabase/scripts/restore.sh --list
#   /opt/supabase/scripts/restore.sh --latest
#
# =============================================================================
set -euo pipefail

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

if [ ! -f "$SUPABASE_DIR/.env" ]; then
    echo -e "${RED}ERROR: $SUPABASE_DIR/.env nicht gefunden${NC}"
    exit 1
fi

get_env() { grep "^$1=" "$SUPABASE_DIR/.env" | cut -d'=' -f2-; }

S3_ENDPOINT=$(get_env S3_ENDPOINT)
S3_BACKUP_BUCKET=$(get_env S3_BACKUP_BUCKET)
BACKUP_ENCRYPTION_KEY=$(get_env BACKUP_ENCRYPTION_KEY)
export AWS_ACCESS_KEY_ID=$(get_env S3_ACCESS_KEY)
export AWS_SECRET_ACCESS_KEY=$(get_env S3_SECRET_KEY)

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

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }

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

# Führt SQL-Datei im Container aus (docker cp + psql -f)
exec_sql_file() {
    local host_file=$1
    shift
    local container_path="/tmp/restore_$(basename "$host_file")"

    docker cp "$host_file" supabase-db:"$container_path"
    docker compose exec -T db psql -U postgres "$@" -f "$container_path" 2>&1
    docker compose exec -T db rm -f "$container_path"
}

restore_database() {
    local backup_dir=$1

    local roles_file="$backup_dir/backup_roles.sql"
    local schema_file="$backup_dir/backup_schema.sql"
    local data_file="$backup_dir/backup_data.sql"

    for f in "$roles_file" "$schema_file" "$data_file"; do
        if [ ! -f "$f" ]; then
            print_error "Dump-Datei nicht gefunden: $f"
            exit 1
        fi
    done

    cd "$SUPABASE_DIR"

    # 1. Rollen wiederherstellen
    echo "  Rollen wiederherstellen..."
    exec_sql_file "$roles_file" 2>&1 | \
        grep -iE "^(ERROR|FATAL)" | \
        grep -v "already exists" | \
        grep -v "reserved role" | \
        grep -v "must be superuser" | \
        grep -v "permission denied" || true

    # 2. Schema wiederherstellen (--single-transaction für Atomarität)
    echo "  Schema wiederherstellen..."
    local schema_errors
    schema_errors=$(exec_sql_file "$schema_file" --single-transaction 2>&1 | \
        grep -iE "^(ERROR|FATAL)" | \
        grep -v "already exists" | \
        grep -v "reserved role" | \
        grep -v "must be superuser" | \
        grep -v "permission denied" | \
        grep -v "must be owner of" || true)

    if [ -n "$schema_errors" ]; then
        print_warning "Schema-Fehler (möglicherweise unkritisch):"
        echo "$schema_errors"
    fi

    # 3. Daten wiederherstellen (session_replication_role = replica deaktiviert Trigger)
    echo "  Daten wiederherstellen..."
    local data_errors
    data_errors=$(exec_sql_file "$data_file" \
        --single-transaction \
        --command "SET session_replication_role = replica" 2>&1 | \
        grep -iE "^(ERROR|FATAL)" | \
        grep -v "already exists" | \
        grep -v "permission denied" | \
        grep -v "must be owner of" || true)

    if [ -n "$data_errors" ]; then
        print_warning "Daten-Fehler (möglicherweise unkritisch):"
        echo "$data_errors"
    fi

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

decrypt_backup() {
    local encrypted_file=$1
    local output_file=$2

    if [ -n "${BACKUP_ENCRYPTION_KEY:-}" ]; then
        echo "Entschlüssle Backup..."
        gpg --batch --yes --passphrase "$BACKUP_ENCRYPTION_KEY" \
            -d "$encrypted_file" > "$output_file"
        rm -f "$encrypted_file"
        print_success "Backup entschlüsselt"
    else
        if [[ "$encrypted_file" == *.gpg ]]; then
            print_error "Backup ist verschlüsselt, aber BACKUP_ENCRYPTION_KEY fehlt!"
            exit 1
        fi
        mv "$encrypted_file" "$output_file"
    fi
}

# =============================================================================
# Hauptfunktion
# =============================================================================

do_restore() {
    local backup_file=$1

    print_header "Supabase Disaster Recovery"
    echo "Backup: $backup_file"
    echo ""

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
    print_header "1/6 - Backup herunterladen"
    local download_file="$RESTORE_DIR/backup.tar.gz"
    if [[ "$backup_file" == *.gpg ]]; then
        download_file="$RESTORE_DIR/backup.tar.gz.gpg"
    fi
    download_backup "$backup_file" "$download_file"

    # 2. Entschlüsseln
    print_header "2/6 - Backup entschlüsseln"
    if [[ "$backup_file" == *.gpg ]]; then
        decrypt_backup "$download_file" "$RESTORE_DIR/backup.tar.gz"
    else
        echo "Nicht verschlüsselt, überspringe..."
    fi

    # 3. Entpacken
    print_header "3/6 - Backup entpacken"
    tar -xzf "$RESTORE_DIR/backup.tar.gz" -C "$RESTORE_DIR"
    print_success "Backup entpackt"

    # 4. Stop
    print_header "4/6 - Services stoppen"
    stop_services

    # 5. Restore
    print_header "5/6 - Datenbank wiederherstellen"
    start_database

    # Backup-Verzeichnis mit den 3 Dump-Dateien finden
    local backup_data_dir=""
    for dir in "$RESTORE_DIR/backup/db-data" "$RESTORE_DIR"; do
        if [ -f "$dir/backup_schema.sql" ] && [ -f "$dir/backup_data.sql" ] && [ -f "$dir/backup_roles.sql" ]; then
            backup_data_dir="$dir"
            break
        fi
    done

    if [ -z "$backup_data_dir" ]; then
        print_error "Kein gültiges Backup gefunden (backup_roles.sql, backup_schema.sql, backup_data.sql fehlen)"
        print_error "Nur Backups im neuen Format (3 separate Dumps) werden unterstützt."
        exit 1
    fi

    restore_database "$backup_data_dir"

    # 6. Start
    print_header "6/6 - Services starten"
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
