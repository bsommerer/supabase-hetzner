#!/bin/bash
# =============================================================================
# Lokaler Backup/Restore Test
# =============================================================================
# Testet die Backup-Funktionalität mit einem lokalen docker-volume-backup
# Container und verifiziert die S3-Verbindung.
#
# Verwendung:
#   ./scripts/test-backup.sh
#
# Voraussetzungen:
#   - Docker muss installiert und laufen
#   - terraform.tfvars muss mit S3 Credentials konfiguriert sein
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

# =============================================================================
# Variablen laden
# =============================================================================

load_vars() {
    local tfvars="$TERRAFORM_DIR/terraform.tfvars"
    local secrets="$TERRAFORM_DIR/secrets.auto.tfvars"

    if [ ! -f "$tfvars" ]; then
        print_error "terraform.tfvars nicht gefunden!"
        echo "Erstelle zuerst die Konfigurationsdatei:"
        echo "  cp terraform/terraform.tfvars.example terraform/terraform.tfvars"
        exit 1
    fi

    # Parse terraform.tfvars (einfache Variante)
    export S3_ENDPOINT=$(grep -E '^s3_endpoint\s*=' "$tfvars" | sed 's/.*=\s*"\(.*\)"/\1/')
    export S3_REGION=$(grep -E '^s3_region\s*=' "$tfvars" | sed 's/.*=\s*"\(.*\)"/\1/' || echo "eu-central-1")
    export S3_ACCESS_KEY=$(grep -E '^s3_access_key\s*=' "$tfvars" | sed 's/.*=\s*"\(.*\)"/\1/')
    export S3_SECRET_KEY=$(grep -E '^s3_secret_key\s*=' "$tfvars" | sed 's/.*=\s*"\(.*\)"/\1/')
    export S3_BACKUP_BUCKET=$(grep -E '^s3_backup_bucket\s*=' "$tfvars" | sed 's/.*=\s*"\(.*\)"/\1/')

    # Optional: Encryption Key
    export BACKUP_ENCRYPTION_KEY=$(grep -E '^backup_encryption_key\s*=' "$tfvars" 2>/dev/null | sed 's/.*=\s*"\(.*\)"/\1/' || echo "")

    # Validierung
    if [ -z "$S3_ENDPOINT" ] || [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ] || [ -z "$S3_BACKUP_BUCKET" ]; then
        print_error "S3 Konfiguration unvollständig in terraform.tfvars!"
        echo "Benötigte Variablen: s3_endpoint, s3_access_key, s3_secret_key, s3_backup_bucket"
        exit 1
    fi

    print_success "Konfiguration geladen"
    echo "  S3 Endpoint: $S3_ENDPOINT"
    echo "  S3 Bucket:   $S3_BACKUP_BUCKET"
    echo "  Encryption:  ${BACKUP_ENCRYPTION_KEY:+aktiviert}${BACKUP_ENCRYPTION_KEY:-deaktiviert}"
}

# =============================================================================
# Test Funktionen
# =============================================================================

test_s3_connection() {
    echo -e "${YELLOW}Test 1: S3 Verbindung prüfen...${NC}"

    if docker run --rm \
        -e AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
        -e AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
        amazon/aws-cli \
        --endpoint-url "$S3_ENDPOINT" \
        s3 ls "s3://$S3_BACKUP_BUCKET/" --region "$S3_REGION" &>/dev/null; then
        print_success "S3 Verbindung OK"
        return 0
    else
        print_error "S3 Verbindung fehlgeschlagen"
        echo "Prüfe S3 Credentials und Bucket-Name in terraform.tfvars"
        return 1
    fi
}

test_backup_create() {
    echo -e "${YELLOW}Test 2: Test-Backup erstellen...${NC}"

    # Erstelle Test-Volume mit Daten
    docker volume create test-backup-data &>/dev/null || true
    docker run --rm -v test-backup-data:/data alpine sh -c \
        "echo 'Test data created at $(date)' > /data/test.txt && echo 'Supabase Backup Test' >> /data/test.txt"

    # Backup Environment vorbereiten
    local backup_env=""
    backup_env="$backup_env -e AWS_ACCESS_KEY_ID=$S3_ACCESS_KEY"
    backup_env="$backup_env -e AWS_SECRET_ACCESS_KEY=$S3_SECRET_KEY"
    backup_env="$backup_env -e AWS_S3_BUCKET_NAME=$S3_BACKUP_BUCKET"
    backup_env="$backup_env -e AWS_S3_PATH=test-backups"
    backup_env="$backup_env -e AWS_ENDPOINT=$S3_ENDPOINT"
    backup_env="$backup_env -e BACKUP_FILENAME=test-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    backup_env="$backup_env -e BACKUP_COMPRESSION=gz"

    # GPG Encryption wenn konfiguriert
    if [ -n "${BACKUP_ENCRYPTION_KEY:-}" ]; then
        backup_env="$backup_env -e GPG_PASSPHRASE=$BACKUP_ENCRYPTION_KEY"
        echo "  Mit GPG Verschlüsselung..."
    fi

    # Führe Backup aus
    if docker run --rm \
        $backup_env \
        -v test-backup-data:/backup/data:ro \
        offen/docker-volume-backup:v2 \
        backup &>/dev/null; then
        print_success "Test-Backup erstellt"
        return 0
    else
        print_error "Backup fehlgeschlagen"
        return 1
    fi
}

test_backup_verify() {
    echo -e "${YELLOW}Test 3: Backup in S3 verifizieren...${NC}"

    local backup_list=$(docker run --rm \
        -e AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
        -e AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
        amazon/aws-cli \
        --endpoint-url "$S3_ENDPOINT" \
        s3 ls "s3://$S3_BACKUP_BUCKET/test-backups/" --region "$S3_REGION" 2>/dev/null || echo "")

    if echo "$backup_list" | grep -q "test-backup"; then
        print_success "Backup in S3 gefunden"
        echo "$backup_list" | tail -3 | while read line; do
            echo "  $line"
        done
        return 0
    else
        print_error "Backup nicht in S3 gefunden"
        return 1
    fi
}

test_restore() {
    echo -e "${YELLOW}Test 4: Restore simulieren...${NC}"

    # Finde neuestes Test-Backup
    local backup_file=$(docker run --rm \
        -e AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
        -e AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
        amazon/aws-cli \
        --endpoint-url "$S3_ENDPOINT" \
        s3 ls "s3://$S3_BACKUP_BUCKET/test-backups/" --region "$S3_REGION" 2>/dev/null | \
        grep "test-backup" | tail -1 | awk '{print $4}')

    if [ -z "$backup_file" ]; then
        print_error "Kein Test-Backup gefunden"
        return 1
    fi

    echo "  Backup-Datei: $backup_file"

    # Download
    local temp_dir=$(mktemp -d)
    local download_file="$temp_dir/backup.tar.gz"

    if [[ "$backup_file" == *.gpg ]]; then
        download_file="$temp_dir/backup.tar.gz.gpg"
    fi

    docker run --rm \
        -e AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
        -e AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
        -v "$temp_dir:/download" \
        amazon/aws-cli \
        --endpoint-url "$S3_ENDPOINT" \
        s3 cp "s3://$S3_BACKUP_BUCKET/test-backups/$backup_file" "/download/$(basename $download_file)" \
        --region "$S3_REGION" &>/dev/null

    # Entschlüsseln wenn nötig
    if [[ "$backup_file" == *.gpg ]]; then
        if [ -n "${BACKUP_ENCRYPTION_KEY:-}" ]; then
            echo "  Entschlüssle Backup..."
            echo "$BACKUP_ENCRYPTION_KEY" | gpg --batch --yes --passphrase-fd 0 \
                -d "$download_file" > "$temp_dir/backup.tar.gz" 2>/dev/null
            download_file="$temp_dir/backup.tar.gz"
        else
            print_error "Backup ist verschlüsselt, aber BACKUP_ENCRYPTION_KEY fehlt!"
            rm -rf "$temp_dir"
            return 1
        fi
    fi

    # Verify tarball
    if tar -tzf "$temp_dir/backup.tar.gz" &>/dev/null; then
        print_success "Backup-Archiv valide"
    else
        print_error "Backup-Archiv korrupt"
        rm -rf "$temp_dir"
        return 1
    fi

    # Cleanup
    rm -rf "$temp_dir"
    return 0
}

cleanup() {
    echo -e "${YELLOW}Cleanup...${NC}"

    # Lösche Test-Volume
    docker volume rm test-backup-data 2>/dev/null || true

    # Lösche Test-Backups aus S3
    docker run --rm \
        -e AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
        -e AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
        amazon/aws-cli \
        --endpoint-url "$S3_ENDPOINT" \
        s3 rm "s3://$S3_BACKUP_BUCKET/test-backups/" --recursive --region "$S3_REGION" 2>/dev/null || true

    print_success "Cleanup abgeschlossen"
}

# =============================================================================
# Main
# =============================================================================

main() {
    print_header "Backup/Restore Test Suite"

    # Prüfe Docker
    if ! command -v docker &> /dev/null; then
        print_error "Docker nicht gefunden!"
        exit 1
    fi

    if ! docker info &>/dev/null; then
        print_error "Docker läuft nicht!"
        exit 1
    fi

    load_vars

    local failed=0

    echo ""
    test_s3_connection || ((failed++))
    echo ""
    test_backup_create || ((failed++))
    echo ""
    test_backup_verify || ((failed++))
    echo ""
    test_restore || ((failed++))
    echo ""

    cleanup

    echo ""
    if [ $failed -eq 0 ]; then
        echo -e "${GREEN}======================================${NC}"
        echo -e "${GREEN} Alle Tests erfolgreich!${NC}"
        echo -e "${GREEN}======================================${NC}"
        exit 0
    else
        echo -e "${RED}======================================${NC}"
        echo -e "${RED} $failed Test(s) fehlgeschlagen!${NC}"
        echo -e "${RED}======================================${NC}"
        exit 1
    fi
}

main "$@"
